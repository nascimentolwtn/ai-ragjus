"""
AI-RAGJus Web GUI (Phase 1)

A thin Flask layer that bridges the existing Bash RAG engine (src/*.sh) as a
subprocess. The "brain" (embeddings, cosine search, prompt assembly, Ollama
streaming) stays in src/rag_query.sh + src/ai.sh + src/vector.sh; this app
only orchestrates the request/response cycle and persists chat history in a
GUI-owned SQLite database (web/data/chat_history.db), separate from the
vector store (.cache_vetorial/rag_store.db).

Run directly for development:
    python3 web/app.py
or via the launcher:
    ./web/run.sh
"""
import json
import os
import sqlite3
import subprocess
import sys
import threading
from pathlib import Path

from flask import Flask, Response, jsonify, render_template, request, stream_with_context

# Make `import db`/`import memory` work regardless of how this module is
# invoked (python web/app.py, flask --app web/app run, gunicorn web.app:app, ...).
sys.path.insert(0, str(Path(__file__).resolve().parent))
import db  # noqa: E402
import ingest  # noqa: E402
import memory  # noqa: E402
from context_tracker import ContextTracker  # noqa: E402

BASE_DIR = Path(__file__).resolve().parent.parent
RAG_QUERY_SCRIPT = BASE_DIR / "src" / "rag_query.sh"
SYNC_QUERY_SCRIPT = BASE_DIR / "src" / "sync_query.sh"
CONFIG_PATH = BASE_DIR / "config.conf"

# Guards against two /api/sync runs racing on the shared single-threaded
# SQLite store (see "Critical Constraints" in CLAUDE.md). Sync is a rare,
# manually-triggered action, so a simple non-blocking lock is enough.
_sync_lock = threading.Lock()

DEFAULT_CONFIG = {
    "PASTA_ALVO": "./docs",
    "CACHE_DIR": "./.cache_vetorial",
    "OLLAMA_URL": "http://localhost:11434",
    "MODELO_IA": "qwen2.5:1.5b",
    "MODELO_EMBEDDING": "nomic-embed-text",
    "MAX_FILE_SIZE_MB": "50",
    "CHUNK_SIZE": "1000",
    "CHUNK_OVERLAP": "200",
    "TEMPERATURA": "0",
    "AUTO_MEMORY": "1",
    "CONTEXT_WINDOW": "16384",
    "TOKEN_RATIO": "0.30",
}

app = Flask(__name__)
db.init_db()


def load_config():
    """Parse config.conf (simple KEY="value" lines), mirroring src/config.sh.

    config.conf remains the single source of truth for model/chunking
    settings; this is a read-only mirror for display in the UI.
    """
    config = dict(DEFAULT_CONFIG)
    if CONFIG_PATH.exists():
        for line in CONFIG_PATH.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key in config:
                config[key] = value
    return config


# Bound multipart upload size (item 9 attach-file) at the Flask level too, not
# just in ingest.py after the fact - avoids buffering an oversized upload to
# disk before rejecting it. +1MB slack covers multipart boundary/header overhead.
try:
    _max_upload_mb = float(load_config().get("MAX_FILE_SIZE_MB", 50) or 50)
except (TypeError, ValueError):
    _max_upload_mb = 50.0
app.config["MAX_CONTENT_LENGTH"] = int(_max_upload_mb * 1024 * 1024) + 1024 * 1024


def _derive_title(text, max_words=8):
    words = text.strip().split()
    title = " ".join(words[:max_words])
    if len(words) > max_words:
        title += "..."
    return title or "Nova conversa"


def _sse(payload):
    """Format one Server-Sent Events frame."""
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


@app.route("/")
def index():
    config = load_config()
    return render_template("chat.html", config=config)


@app.route("/api/sessions", methods=["GET"])
def api_list_sessions():
    try:
        limit = int(request.args.get("limit", 30))
    except (TypeError, ValueError):
        limit = 30
    try:
        offset = int(request.args.get("offset", 0))
    except (TypeError, ValueError):
        offset = 0
    limit = max(1, min(limit, 100))
    offset = max(0, offset)
    return jsonify(db.list_sessions(limit=limit, offset=offset))


@app.route("/api/sessions", methods=["POST"])
def api_create_session():
    """Create a new empty session (fixes issue #3: scope can now be set before first message)."""
    payload = request.get_json(silent=True) or {}
    title = (payload.get("title") or "Nova conversa").strip() or "Nova conversa"
    session_id = db.create_session(title)
    return jsonify({"ok": True, "session_id": session_id}), 201


@app.route("/api/documents/tree", methods=["GET"])
def api_documents_tree():
    """Hierarchical folder/doc structure from the RAG vector store (read-only)."""
    config = load_config()
    cache_dir = Path(config["CACHE_DIR"])
    if not cache_dir.is_absolute():
        cache_dir = BASE_DIR / cache_dir
    db_path = cache_dir / "rag_store.db"
    if not db_path.exists():
        return jsonify({"folders": {}, "total": 0})

    with sqlite3.connect(str(db_path)) as conn:
        rows = conn.execute(
            "SELECT DISTINCT caminho_arquivo FROM document_chunks ORDER BY caminho_arquivo"
        ).fetchall()

    pasta_alvo = Path(config["PASTA_ALVO"])
    if not pasta_alvo.is_absolute():
        pasta_alvo = BASE_DIR / pasta_alvo

    tree = {}
    for (filepath,) in rows:
        p = Path(filepath)
        try:
            rel = p.relative_to(pasta_alvo)      # display label (relative path)
        except ValueError:
            rel = p                               # doc outside current PASTA_ALVO
        folder = str(rel.parent) if str(rel.parent) != "." else "raiz"
        tree.setdefault(folder, []).append({
            "name": rel.name,
            "path": filepath,                     # absolute — must match DB exactly
        })

    return jsonify({"folders": tree, "total": len(rows)})


@app.route("/api/sessions/<int:session_id>", methods=["GET"])
def api_session_detail(session_id):
    session = db.get_session(session_id)
    if not session:
        return jsonify({"error": "Sessão não encontrada."}), 404
    return jsonify({"session": session, "messages": db.get_messages(session_id)})


@app.route("/api/sessions/<int:session_id>", methods=["PATCH"])
def api_rename_session(session_id):
    if not db.get_session(session_id):
        return jsonify({"error": "Sessão não encontrada."}), 404

    payload = request.get_json(silent=True) or {}
    title = (payload.get("title") or "").strip()
    if not title:
        return jsonify({"error": "Título não pode ser vazio."}), 400
    if len(title) > 120:
        title = title[:120]

    db.update_session_title(session_id, title)
    return jsonify({"ok": True, "title": title})


@app.route("/api/sessions/<int:session_id>", methods=["DELETE"])
def api_delete_session(session_id):
    if not db.get_session(session_id):
        return jsonify({"error": "Sessão não encontrada."}), 404
    db.delete_session(session_id)
    return jsonify({"ok": True})


@app.route("/api/sessions/<int:session_id>/scope", methods=["GET"])
def api_get_session_scope(session_id):
    """Fetch current document scope for a session."""
    if not db.get_session(session_id):
        return jsonify({"error": "Sessão não encontrada."}), 404
    scope = db.get_session_scope(session_id)
    if not scope:
        return jsonify({"selected_docs": [], "total_available": None})
    return jsonify(scope)


@app.route("/api/sessions/<int:session_id>/scope", methods=["POST"])
def api_set_session_scope(session_id):
    """Set document scope for a session."""
    if not db.get_session(session_id):
        return jsonify({"error": "Sessão não encontrada."}), 404

    payload = request.get_json(silent=True) or {}
    selected_docs = payload.get("selected_docs", [])
    if not isinstance(selected_docs, list) or \
            not all(isinstance(d, str) for d in selected_docs):
        return jsonify({"error": "selected_docs deve ser uma lista de caminhos."}), 400

    total = payload.get("total_available")
    db.set_session_scope(session_id, selected_docs, total)
    return jsonify({"ok": True, "selected_docs": selected_docs,
                    "count": len(selected_docs)})


@app.route("/api/sessions/<int:session_id>/context-usage", methods=["POST"])
def api_context_usage(session_id):
    """Per-turn context window usage estimate (see web/context_tracker.py).
    Body (optional): {"retrieved_docs": <chars>, "query": <chars>}.
    """
    if not db.get_session(session_id):
        return jsonify({"error": "Sessão não encontrada."}), 404

    config = load_config()
    try:
        context_window = int(config.get("CONTEXT_WINDOW", 16384))
    except (TypeError, ValueError):
        context_window = 16384
    try:
        token_ratio = float(config.get("TOKEN_RATIO", 0.30))
    except (TypeError, ValueError):
        token_ratio = 0.30

    tracker = ContextTracker(context_window=context_window, token_ratio=token_ratio)
    prompt_estimate = request.get_json(silent=True) or {}
    usage = tracker.calculate_usage(session_id, prompt_char_estimate=prompt_estimate)
    return jsonify(usage)


@app.route("/api/sessions/<int:session_id>/memory", methods=["GET"])
def api_get_session_memory(session_id):
    """M3 mini-UI: list facts remembered for this session."""
    if not db.get_session(session_id):
        return jsonify({"error": "Sessão não encontrada."}), 404
    return jsonify({"facts": db.get_session_memory(session_id, limit=10)})


@app.route("/api/sessions/<int:session_id>/memory/<int:memory_id>", methods=["DELETE"])
def api_delete_session_memory(session_id, memory_id):
    if not db.get_session(session_id):
        return jsonify({"error": "Sessão não encontrada."}), 404
    db.delete_session_memory_item(session_id, memory_id)
    return jsonify({"ok": True})


@app.route("/api/sessions/<int:session_id>/attach-file", methods=["POST"])
def api_attach_file(session_id):
    """Backlog item 9: attach a file to THIS session only.

    Extracts + chunks + embeds via src/attach_file.sh (reusing the CLI's
    extrair_texto_limpo / fatiar_texto / gerar_embedding), then stores the
    chunks in the GUI-owned session_embeddings table. Never written to
    .cache_vetorial/rag_store.db - closing/deleting the session discards it
    (cascade delete, see web/db.py schema).
    """
    if not db.get_session(session_id):
        return jsonify({"error": "Sessão não encontrada."}), 404

    file_storage = request.files.get("file")
    if not file_storage or not file_storage.filename:
        return jsonify({"error": "Nenhum arquivo enviado."}), 400

    config = load_config()
    try:
        result = ingest.attach_file(session_id, file_storage, config)
    except ingest.AttachFileError as exc:
        return jsonify({"error": str(exc)}), 400
    except Exception as exc:  # pragma: no cover - defensive, never 500 silently
        app.logger.exception("attach-file failed for session %s", session_id)
        return jsonify({"error": f"Falha inesperada ao processar o arquivo: {exc}"}), 500

    return jsonify({"status": "ok", **result}), 201


@app.route("/api/sessions/<int:session_id>/attachments", methods=["GET"])
def api_list_attachments(session_id):
    """List files currently attached to this session (for UI restore on reload)."""
    if not db.get_session(session_id):
        return jsonify({"error": "Sessão não encontrada."}), 404
    return jsonify({"attachments": db.list_session_attachments(session_id)})


@app.route("/api/chat", methods=["POST"])
def api_chat():
    payload = request.get_json(silent=True) or {}
    query = (payload.get("query") or "").strip()
    session_id = payload.get("session_id")

    if not query:
        return jsonify({"error": "Pergunta vazia."}), 400

    if session_id:
        session_id = int(session_id)
        if not db.get_session(session_id):
            session_id = db.create_session(_derive_title(query))
    else:
        session_id = db.create_session(_derive_title(query))

    db.add_message(session_id, "user", query)

    config = load_config()

    def generate():
        env = os.environ.copy()
        env["NON_INTERACTIVE"] = "1"

        # Pass document scope (if any) to the RAG subprocess via env var.
        scope = db.get_session_scope(session_id)
        inline_docs = payload.get("selected_docs")          # first-message fallback
        if inline_docs and not scope:
            db.set_session_scope(session_id, inline_docs)
            scope = {"selected_docs": inline_docs}
        if scope and scope["selected_docs"]:
            env["SCOPE_DOCS"] = json.dumps(scope["selected_docs"], ensure_ascii=False)

        # Item 9: let rag_query.sh merge in this session's attached-file chunks
        # (session_embeddings table) ahead of the global vector store results.
        # Cheap no-op when the session has no attachments.
        env["SESSION_EMBED_DB"] = str(db.DB_PATH)
        env["SESSION_ID"] = str(session_id)

        # M0/M3/M4: inject accumulated session + global memory facts, if any.
        memory_context = memory.build_memory_context(session_id)
        if memory_context:
            env["RAG_MEMORY_CONTEXT"] = memory_context

        # Let the browser know which session this turn belongs to (important
        # when the client started with no session_id and one was just created).
        yield _sse({"type": "session", "session_id": session_id})

        answer_parts = []
        sources = []
        saw_error = False

        try:
            proc = subprocess.Popen(
                ["bash", str(RAG_QUERY_SCRIPT), query],
                cwd=str(BASE_DIR),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                text=True,
                bufsize=1,
            )
        except OSError as exc:
            yield _sse({"type": "error", "content": f"Falha ao iniciar o motor RAG: {exc}"})
            yield _sse({"type": "done"})
            return

        try:
            for raw_line in proc.stdout:
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except ValueError:
                    # Non-JSON noise on stdout (shouldn't normally happen) -
                    # ignore rather than break the stream.
                    continue

                etype = event.get("type")
                if etype == "token":
                    answer_parts.append(event.get("content", ""))
                    yield _sse(event)
                elif etype == "sources":
                    sources = event.get("content", []) or []
                    yield _sse(event)
                elif etype == "error":
                    saw_error = True
                    yield _sse(event)
                elif etype == "stats":
                    # Exact prompt_eval_count from Ollama; frontend uses this
                    # to replace the char-based estimate retroactively.
                    yield _sse(event)
                elif etype == "done":
                    yield _sse(event)
        finally:
            proc.wait()
            stderr_output = proc.stderr.read() if proc.stderr else ""
            if stderr_output.strip():
                app.logger.warning("rag_query.sh stderr: %s", stderr_output.strip())

        full_answer = "".join(answer_parts)
        if full_answer:
            db.add_message(session_id, "assistant", full_answer, sources)
        elif not saw_error:
            # Should not normally happen; keep history consistent either way.
            db.add_message(session_id, "assistant", "", sources)

        # M3/M4: extract memory facts off-thread so it never delays the SSE
        # "done" event. Best-effort (memory.record_turn_memory swallows its
        # own errors); skipped entirely if the turn produced no real answer.
        if full_answer and config.get("AUTO_MEMORY", "1") != "0":
            threading.Thread(
                target=memory.record_turn_memory,
                args=(session_id, query, full_answer, config),
                daemon=True,
            ).start()

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


@app.route("/api/sync", methods=["POST"])
def api_sync():
    """Trigger a document re-sync (src/sync_query.sh -> sincronizar_documentos)
    without stopping the web server, streaming progress back over SSE.

    Reuses the same subprocess + NON_INTERACTIVE=1 + JSON-lines pattern as
    /api/chat. Concurrent sync requests are rejected (single-threaded SQLite
    store is shared with the CLI); the button on the client is also disabled
    while a sync is in flight, but the lock protects against other clients
    (other tabs, the CLI, etc.) racing it too.
    """
    if not _sync_lock.acquire(blocking=False):
        return jsonify({
            "status": "error",
            "message": "Uma sincronização já está em andamento. Aguarde a conclusão.",
        }), 409

    def generate():
        env = os.environ.copy()
        env["NON_INTERACTIVE"] = "1"

        try:
            try:
                proc = subprocess.Popen(
                    ["bash", str(SYNC_QUERY_SCRIPT)],
                    cwd=str(BASE_DIR),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=env,
                    text=True,
                    bufsize=1,
                )
            except OSError as exc:
                yield _sse({"type": "error", "content": f"Falha ao iniciar sincronização: {exc}"})
                yield _sse({"type": "done"})
                return

            try:
                for raw_line in proc.stdout:
                    line = raw_line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except ValueError:
                        # Non-JSON noise on stdout - ignore rather than break the stream.
                        continue

                    etype = event.get("type")
                    if etype in ("progress", "error", "complete", "done"):
                        yield _sse(event)
            finally:
                proc.wait()
                stderr_output = proc.stderr.read() if proc.stderr else ""
                if stderr_output.strip():
                    app.logger.warning("sync_query.sh stderr: %s", stderr_output.strip())
        finally:
            _sync_lock.release()

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


@app.errorhandler(413)
def _handle_upload_too_large(_exc):
    """JSON error for oversized attach-file uploads (see MAX_CONTENT_LENGTH),
    instead of Flask's default HTML error page - the client always expects JSON.
    """
    limit_mb = app.config.get("MAX_CONTENT_LENGTH", 0) / (1024 * 1024)
    return jsonify({"error": f"Arquivo excede o limite de {limit_mb:.0f}MB."}), 413


@app.route("/settings")
def settings_page():
    """M4: read-only config.conf reference + global memory inspector."""
    config = load_config()
    return render_template("settings.html", config=config, memory=db.list_global_memory())


@app.route("/api/memory/global", methods=["GET"])
def api_list_global_memory():
    return jsonify(db.list_global_memory())


@app.route("/api/memory/global", methods=["POST"])
def api_create_global_memory():
    payload = request.get_json(silent=True) or {}
    key = (payload.get("key") or "").strip()
    value = (payload.get("value") or "").strip()
    if not key or len(key) > 60:
        return jsonify({"error": "Chave inválida (obrigatória, até 60 caracteres)."}), 400
    if not value or len(value) > 500:
        return jsonify({"error": "Valor inválido (obrigatório, até 500 caracteres)."}), 400
    entry = db.upsert_global_memory(key, value, source="manual")
    return jsonify({"ok": True, "entry": entry}), 201


@app.route("/api/memory/global/<int:memory_id>", methods=["PATCH"])
def api_update_global_memory(memory_id):
    if not db.get_global_memory(memory_id):
        return jsonify({"error": "Entrada não encontrada."}), 404

    payload = request.get_json(silent=True) or {}
    if "enabled" in payload:
        db.set_global_memory_enabled(memory_id, bool(payload["enabled"]))

    key = payload.get("key")
    value = payload.get("value")
    if key is not None:
        key = key.strip()
        if not key or len(key) > 60:
            return jsonify({"error": "Chave inválida."}), 400
    if value is not None:
        value = value.strip()
        if not value or len(value) > 500:
            return jsonify({"error": "Valor inválido."}), 400
    if key is not None or value is not None:
        db.update_global_memory(memory_id, key=key, value=value)

    return jsonify({"ok": True, "entry": db.get_global_memory(memory_id)})


@app.route("/api/memory/global/<int:memory_id>", methods=["DELETE"])
def api_delete_global_memory(memory_id):
    if not db.get_global_memory(memory_id):
        return jsonify({"error": "Entrada não encontrada."}), 404
    db.delete_global_memory(memory_id)
    return jsonify({"ok": True})


# Manual test commands (Phase 2 — scope selector backend, no UI yet):
#
#   # 1. Create a session
#   SESS=$(curl -s -X POST http://localhost:5000/api/sessions \
#     -H "Content-Type: application/json" \
#     -d '{"title":"Test Scope"}' | jq -r .session_id)
#
#   # 2. Get document tree
#   curl -s http://localhost:5000/api/documents/tree | jq '.total'
#
#   # 3. Set scope to first 2 docs
#   DOCS=$(curl -s http://localhost:5000/api/documents/tree \
#     | jq -c '.folders | to_entries | .[0].value | .[0:2] | map(.path)')
#   curl -s -X POST http://localhost:5000/api/sessions/$SESS/scope \
#     -H "Content-Type: application/json" \
#     -d "{\"selected_docs\":$DOCS}" | jq '.count'
#
#   # 4. Retrieve scope
#   curl -s http://localhost:5000/api/sessions/$SESS/scope | jq '.selected_docs | length'
#
#   # 5. Clear scope (empty list -> reverts to all documents)
#   curl -s -X POST http://localhost:5000/api/sessions/$SESS/scope \
#     -H "Content-Type: application/json" \
#     -d '{"selected_docs":[]}' | jq '.count'
#
#   # 6. Verify it's gone (back to all docs)
#   curl -s http://localhost:5000/api/sessions/$SESS/scope | jq '.selected_docs'
#
#   # 7. Chat with scope (requires Ollama running)
#   curl -s -X POST http://localhost:5000/api/chat \
#     -H "Content-Type: application/json" \
#     -d "{\"session_id\":$SESS, \"query\":\"test\", \"selected_docs\":$DOCS}" \
#     | head -20

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True, threaded=True)

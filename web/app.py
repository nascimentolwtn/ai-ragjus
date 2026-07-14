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
import subprocess
import sys
import threading
from pathlib import Path

from flask import Flask, Response, jsonify, render_template, request, stream_with_context

# Make `import db` work regardless of how this module is invoked
# (python web/app.py, flask --app web/app run, gunicorn web.app:app, ...).
sys.path.insert(0, str(Path(__file__).resolve().parent))
import db  # noqa: E402

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
    sessions = db.list_sessions()
    return render_template("chat.html", config=config, sessions=sessions)


@app.route("/api/sessions", methods=["GET"])
def api_list_sessions():
    return jsonify(db.list_sessions())


@app.route("/api/sessions/<int:session_id>", methods=["GET"])
def api_session_detail(session_id):
    session = db.get_session(session_id)
    if not session:
        return jsonify({"error": "Sessão não encontrada."}), 404
    return jsonify({"session": session, "messages": db.get_messages(session_id)})


@app.route("/api/sessions/<int:session_id>", methods=["DELETE"])
def api_delete_session(session_id):
    db.delete_session(session_id)
    return jsonify({"ok": True})


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

    def generate():
        env = os.environ.copy()
        env["NON_INTERACTIVE"] = "1"

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


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True, threaded=True)

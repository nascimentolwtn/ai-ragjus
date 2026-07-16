"""
AI-RAGJus Web GUI - session-scoped file attachments (backlog item 9).

Lets a user drag/drop or pick a file to instantly add its content to the
CURRENT chat session's RAG context, without touching the global vector store
(.cache_vetorial/rag_store.db). Extraction, chunking and embedding are
delegated to src/attach_file.sh, which sources the very same
src/ingest.sh::extrair_texto_limpo / fatiar_texto and src/ai.sh::gerar_embedding
functions used by the CLI's sincronizar_documentos - this module intentionally
never reimplements chunking or embedding in Python; it only spawns that
subprocess and persists the resulting rows into the GUI-owned
session_embeddings table (web/data/chat_history.db).
"""
import json
import os
import subprocess
import tempfile
from pathlib import Path

import db

BASE_DIR = Path(__file__).resolve().parent.parent
ATTACH_SCRIPT = BASE_DIR / "src" / "attach_file.sh"

# Kept in sync with the napkin scope (item 9) and src/ingest.sh::extrair_texto_limpo.
ALLOWED_EXTENSIONS = {"pdf", "docx", "txt", "md", "json", "py"}

ATTACH_TIMEOUT_SECONDS = 300


class AttachFileError(Exception):
    """User-facing failure (bad extension, empty file, extraction failure, ...)."""


def _extension(filename):
    return (filename.rsplit(".", 1)[-1] if "." in filename else "").lower()


def attach_file(session_id, file_storage, config):
    """Extract + chunk + embed an uploaded file and store the chunks in
    session_embeddings for `session_id`.

    Returns {"chunks_added": int, "size_bytes": int, "file_name": str}.
    Raises AttachFileError for any user-facing failure (never leaks a stack
    trace to the caller - app.py maps this to a 400 response).
    """
    filename = (file_storage.filename or "").strip() or "arquivo"
    ext = _extension(filename)
    if ext not in ALLOWED_EXTENSIONS:
        raise AttachFileError(
            "Formato não suportado: ." + (ext or "?") + ". Use: "
            + ", ".join(sorted(ALLOWED_EXTENSIONS))
        )

    try:
        max_mb = float(config.get("MAX_FILE_SIZE_MB", 50) or 50)
    except (TypeError, ValueError):
        max_mb = 50.0

    tmp_dir = Path(tempfile.mkdtemp(prefix="ragjus_attach_"))
    tmp_path = tmp_dir / Path(filename).name  # strip any path components

    try:
        file_storage.save(str(tmp_path))
        size_bytes = tmp_path.stat().st_size

        if size_bytes == 0:
            raise AttachFileError("Arquivo vazio.")
        if size_bytes > max_mb * 1024 * 1024:
            raise AttachFileError(f"Arquivo excede o limite de {max_mb:.0f}MB.")

        env = os.environ.copy()
        env["NON_INTERACTIVE"] = "1"

        try:
            proc = subprocess.run(
                ["bash", str(ATTACH_SCRIPT), str(tmp_path)],
                cwd=str(BASE_DIR),
                env=env,
                capture_output=True,
                text=True,
                timeout=ATTACH_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            raise AttachFileError("Tempo esgotado ao processar o arquivo.")
        except OSError as exc:
            raise AttachFileError(f"Falha ao iniciar processamento: {exc}")

        chunks_added = 0
        errors = []
        for raw_line in proc.stdout.splitlines():
            line = raw_line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue  # non-JSON noise, ignore rather than break the batch

            etype = event.get("type")
            if etype == "chunk":
                db.add_session_embedding(
                    session_id=session_id,
                    chunk_id=event.get("index", chunks_added),
                    text=event.get("text", ""),
                    embedding=event.get("embedding"),
                    file_name=filename,
                    size_bytes=size_bytes,
                )
                chunks_added += 1
            elif etype == "error":
                errors.append(event.get("content") or "erro desconhecido")

        if chunks_added == 0:
            detail = errors[0] if errors else "Nenhum trecho pôde ser extraído do arquivo."
            raise AttachFileError(detail)

        return {
            "chunks_added": chunks_added,
            "size_bytes": size_bytes,
            "file_name": filename,
        }
    finally:
        try:
            tmp_path.unlink(missing_ok=True)
            tmp_dir.rmdir()
        except OSError:
            pass

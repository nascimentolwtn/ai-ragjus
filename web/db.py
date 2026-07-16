"""
AI-RAGJus Web GUI - Chat history persistence.

This is a *separate* SQLite database from the RAG vector store
(.cache_vetorial/rag_store.db). It only holds GUI state: chat sessions,
messages and small UI/prompt settings. It never touches document_chunks.
"""
import json
import sqlite3
from contextlib import contextmanager
from pathlib import Path

DB_DIR = Path(__file__).resolve().parent / "data"
DB_PATH = DB_DIR / "chat_history.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT,
    created_at   TEXT DEFAULT (datetime('now')),
    updated_at   TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS messages (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    role         TEXT NOT NULL CHECK (role IN ('user','assistant','system')),
    content      TEXT NOT NULL,
    sources      TEXT,
    created_at   TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS settings (
    key          TEXT PRIMARY KEY,
    value        TEXT
);

CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);

-- Selected document paths per session (absent row = all documents)
CREATE TABLE IF NOT EXISTS session_doc_scope (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id         INTEGER NOT NULL UNIQUE REFERENCES sessions(id) ON DELETE CASCADE,
    selected_docs_json TEXT NOT NULL,          -- JSON array of absolute paths
    total_available    INTEGER,                -- corpus size at selection time (UI breakdown)
    created_at         TEXT DEFAULT (datetime('now')),
    updated_at         TEXT DEFAULT (datetime('now'))
);

-- Optional audit trail of scope edits (useful with RAGSEC audit log)
CREATE TABLE IF NOT EXISTS scope_changes (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id    INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    old_docs_json TEXT,
    new_docs_json TEXT,
    changed_at    TEXT DEFAULT (datetime('now'))
);

-- Per-chat memory: short facts extracted from a session's own turns,
-- injected back into future prompts in that same session (RAG_MEMORY_CONTEXT).
CREATE TABLE IF NOT EXISTS session_memory (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    content     TEXT NOT NULL,
    created_at  TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_session_memory_session ON session_memory(session_id);

-- Global cross-session memory: user-entered or auto-extracted long-term facts.
CREATE TABLE IF NOT EXISTS global_memory (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    key         TEXT NOT NULL UNIQUE,
    value       TEXT NOT NULL,
    source      TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','auto')),
    enabled     INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT DEFAULT (datetime('now')),
    updated_at  TEXT DEFAULT (datetime('now'))
);

-- Session-scoped file attachments (backlog item 9): chunks + embeddings of
-- files dragged/attached into a single chat session. Separate from the RAG
-- vector store (.cache_vetorial/rag_store.db) - never written there, and
-- cascade-deleted automatically when the owning session is deleted (see
-- ON DELETE CASCADE + `PRAGMA foreign_keys = ON` in get_conn()).
CREATE TABLE IF NOT EXISTS session_embeddings (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    chunk_id    INTEGER NOT NULL,
    text        TEXT NOT NULL,
    embedding   TEXT NOT NULL,        -- JSON array (same format as rag_store.db)
    file_name   TEXT NOT NULL,
    size_bytes  INTEGER NOT NULL DEFAULT 0,  -- original file size, repeated per chunk (for the UI file list)
    created_at  TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_session_embeddings_session ON session_embeddings(session_id);
"""


@contextmanager
def get_conn():
    DB_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA busy_timeout = 5000")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db():
    """Create tables if they don't exist yet. Safe to call on every startup."""
    with get_conn() as conn:
        conn.executescript(SCHEMA)
        _migrate(conn)


def _migrate(conn):
    """Lightweight ALTER TABLE migrations for columns added after a DB already
    existed on disk (executescript's CREATE TABLE IF NOT EXISTS won't add
    columns to a table that's already there)."""
    cols = {row["name"] for row in conn.execute("PRAGMA table_info(session_embeddings)")}
    if "size_bytes" not in cols:
        conn.execute(
            "ALTER TABLE session_embeddings ADD COLUMN size_bytes INTEGER NOT NULL DEFAULT 0"
        )


def create_session(title):
    with get_conn() as conn:
        cur = conn.execute("INSERT INTO sessions (title) VALUES (?)", (title,))
        return cur.lastrowid


def update_session_title(session_id, title):
    with get_conn() as conn:
        conn.execute(
            "UPDATE sessions SET title = ?, updated_at = datetime('now') WHERE id = ?",
            (title, session_id),
        )


def list_sessions(limit=30, offset=0):
    """Paginated session list, newest-updated first.

    Fetches `limit + 1` rows to derive `has_more` without a separate
    COUNT(*) query.
    """
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, title, created_at, updated_at FROM sessions "
            "ORDER BY updated_at DESC LIMIT ? OFFSET ?",
            (limit + 1, offset),
        ).fetchall()
    has_more = len(rows) > limit
    sessions = [dict(row) for row in rows[:limit]]
    return {"sessions": sessions, "has_more": has_more}


def get_session(session_id):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id, title, created_at, updated_at FROM sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
        return dict(row) if row else None


def get_messages(session_id):
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, role, content, sources, created_at FROM messages "
            "WHERE session_id = ? ORDER BY id ASC",
            (session_id,),
        ).fetchall()

    result = []
    for row in rows:
        item = dict(row)
        if item.get("sources"):
            try:
                item["sources"] = json.loads(item["sources"])
            except (ValueError, TypeError):
                item["sources"] = []
        else:
            item["sources"] = []
        result.append(item)
    return result


def add_message(session_id, role, content, sources=None):
    sources_json = json.dumps(sources, ensure_ascii=False) if sources else None
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO messages (session_id, role, content, sources) VALUES (?, ?, ?, ?)",
            (session_id, role, content, sources_json),
        )
        conn.execute(
            "UPDATE sessions SET updated_at = datetime('now') WHERE id = ?",
            (session_id,),
        )


def delete_session(session_id):
    with get_conn() as conn:
        conn.execute("DELETE FROM sessions WHERE id = ?", (session_id,))


def get_session_scope(session_id):
    """Fetch selected docs + total_available for a session."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT selected_docs_json, total_available, updated_at "
            "FROM session_doc_scope WHERE session_id = ?",
            (session_id,),
        ).fetchone()
    if not row:
        return None
    try:
        docs = json.loads(row["selected_docs_json"])
    except (ValueError, TypeError):
        docs = []
    return {
        "selected_docs": docs,
        "total_available": row["total_available"],
        "updated_at": row["updated_at"],
    }


def set_session_scope(session_id, selected_docs, total_available=None):
    """Store selected docs. Empty list deletes the scope row (all documents)."""
    with get_conn() as conn:
        # Log the change before updating
        old = conn.execute(
            "SELECT selected_docs_json FROM session_doc_scope WHERE session_id = ?",
            (session_id,),
        ).fetchone()
        conn.execute(
            "INSERT INTO scope_changes (session_id, old_docs_json, new_docs_json) "
            "VALUES (?, ?, ?)",
            (session_id, old["selected_docs_json"] if old else None,
             json.dumps(selected_docs, ensure_ascii=False)),
        )

        if not selected_docs:
            # Empty list = delete scope row, revert to all documents
            conn.execute(
                "DELETE FROM session_doc_scope WHERE session_id = ?", (session_id,)
            )
            return

        # Upsert: insert or update
        conn.execute(
            "INSERT INTO session_doc_scope (session_id, selected_docs_json, total_available) "
            "VALUES (?, ?, ?) "
            "ON CONFLICT(session_id) DO UPDATE SET "
            "  selected_docs_json = excluded.selected_docs_json, "
            "  total_available    = excluded.total_available, "
            "  updated_at         = datetime('now')",
            (session_id, json.dumps(selected_docs, ensure_ascii=False), total_available),
        )


def get_setting(key, default=None):
    with get_conn() as conn:
        row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else default


def set_setting(key, value):
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )


# --- Per-chat memory (M3) --------------------------------------------------

def add_session_memory(session_id, content):
    content = (content or "").strip()
    if not content:
        return
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO session_memory (session_id, content) VALUES (?, ?)",
            (session_id, content),
        )


def get_session_memory(session_id, limit=10):
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, content, created_at FROM session_memory "
            "WHERE session_id = ? ORDER BY id DESC LIMIT ?",
            (session_id, limit),
        ).fetchall()
    # Return oldest-first so the injected block reads chronologically.
    return [dict(row) for row in reversed(rows)]


def prune_session_memory(session_id, keep=10):
    with get_conn() as conn:
        conn.execute(
            "DELETE FROM session_memory WHERE session_id = ? AND id NOT IN ("
            "  SELECT id FROM session_memory WHERE session_id = ? "
            "  ORDER BY id DESC LIMIT ?"
            ")",
            (session_id, session_id, keep),
        )


def delete_session_memory_item(session_id, memory_id):
    with get_conn() as conn:
        conn.execute(
            "DELETE FROM session_memory WHERE session_id = ? AND id = ?",
            (session_id, memory_id),
        )


# --- Global cross-session memory (M4) --------------------------------------

def list_global_memory():
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, key, value, source, enabled, created_at, updated_at "
            "FROM global_memory ORDER BY updated_at DESC"
        ).fetchall()
    entries = [dict(row) for row in rows]
    return {
        "enabled": [e for e in entries if e["enabled"]],
        "disabled": [e for e in entries if not e["enabled"]],
    }


def upsert_global_memory(key, value, source="manual"):
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO global_memory (key, value, source) VALUES (?, ?, ?) "
            "ON CONFLICT(key) DO UPDATE SET "
            "  value = excluded.value, updated_at = datetime('now')",
            (key, value, source),
        )
        row = conn.execute(
            "SELECT id, key, value, source, enabled, created_at, updated_at "
            "FROM global_memory WHERE key = ?", (key,),
        ).fetchone()
    return dict(row) if row else None


def get_global_memory(memory_id):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id, key, value, source, enabled, created_at, updated_at "
            "FROM global_memory WHERE id = ?", (memory_id,),
        ).fetchone()
    return dict(row) if row else None


def update_global_memory(memory_id, key=None, value=None):
    fields, params = [], []
    if key is not None:
        fields.append("key = ?")
        params.append(key)
    if value is not None:
        fields.append("value = ?")
        params.append(value)
    if not fields:
        return
    fields.append("updated_at = datetime('now')")
    params.append(memory_id)
    with get_conn() as conn:
        conn.execute(
            f"UPDATE global_memory SET {', '.join(fields)} WHERE id = ?", params
        )


def set_global_memory_enabled(memory_id, enabled):
    with get_conn() as conn:
        conn.execute(
            "UPDATE global_memory SET enabled = ?, updated_at = datetime('now') WHERE id = ?",
            (1 if enabled else 0, memory_id),
        )


def delete_global_memory(memory_id):
    with get_conn() as conn:
        conn.execute("DELETE FROM global_memory WHERE id = ?", (memory_id,))


def count_auto_global_memory():
    with get_conn() as conn:
        row = conn.execute(
            "SELECT COUNT(*) AS c FROM global_memory WHERE source = 'auto'"
        ).fetchone()
    return row["c"] if row else 0


def evict_oldest_auto_global_memory():
    with get_conn() as conn:
        conn.execute(
            "DELETE FROM global_memory WHERE id = ("
            "  SELECT id FROM global_memory WHERE source = 'auto' "
            "  ORDER BY created_at ASC LIMIT 1"
            ")"
        )


# --- Session-scoped file attachments (item 9) ------------------------------

def add_session_embedding(session_id, chunk_id, text, embedding, file_name, size_bytes=0):
    embedding_json = json.dumps(embedding, ensure_ascii=False)
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO session_embeddings "
            "(session_id, chunk_id, text, embedding, file_name, size_bytes) VALUES (?, ?, ?, ?, ?, ?)",
            (session_id, chunk_id, text, embedding_json, file_name, size_bytes),
        )


def list_session_attachments(session_id):
    """Files attached to a session, one row per file (for the UI file list).

    session_embeddings stores one row per CHUNK, not per file, so `id` here
    is the id of that file's first chunk row. It's returned as the file's
    "attachment id" - delete_session_attachment() below resolves it back to
    a file_name and removes every chunk that shares it.
    """
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT MIN(id) AS id, file_name, COUNT(*) AS chunks_added, "
            "MAX(size_bytes) AS size_bytes "
            "FROM session_embeddings WHERE session_id = ? "
            "GROUP BY file_name ORDER BY MIN(created_at) ASC",
            (session_id,),
        ).fetchall()
    return [dict(row) for row in rows]


def delete_session_attachment(session_id, attachment_id):
    """Remove every chunk of the file represented by `attachment_id` from
    `session_id`'s RAG context, so it stops being used in future queries.

    Returns "not_found" if no chunk with that id exists at all, "forbidden"
    if it exists but belongs to a different session, or the deleted
    file_name on success.
    """
    with get_conn() as conn:
        row = conn.execute(
            "SELECT session_id, file_name FROM session_embeddings WHERE id = ?",
            (attachment_id,),
        ).fetchone()
        if row is None:
            return "not_found"
        if row["session_id"] != session_id:
            return "forbidden"
        conn.execute(
            "DELETE FROM session_embeddings WHERE session_id = ? AND file_name = ?",
            (session_id, row["file_name"]),
        )
        return row["file_name"]

# AI-RAGJus — Flask Web GUI Implementation Plan

## Overview

Replace the CLI (`jus.sh`) with a Flask web GUI in the style of ChatGPT / Open WebUI while **reusing the existing Bash RAG engine** (`src/*.sh`). The backend logic (embeddings, cosine search, Ollama streaming, ingestion) already works and talks to Ollama at `OLLAMA_URL` (`/api/generate`, `/api/embeddings`) and persists chunks in SQLite at `$CACHE_DIR/rag_store.db` (`document_chunks` table). Rather than rewrite this in Python, the Flask layer will **invoke the shell functions as subprocesses** initially, then progressively port hot paths (cosine search, prompt assembly) to Python. The web app is a thin orchestration + presentation layer; the "brain" stays in `src/`.

Tech stack: Flask + Jinja2 templates, vanilla JS + Server-Sent Events (SSE) for streaming, a small CSS file (no build step), SQLite (via `sqlite3` stdlib) for chat history, Gunicorn for production. Everything stays 100% local / air-gapped, matching the project's privacy goal.

## Project Structure

```
web/
├── app.py                  # Flask app factory, route registration
├── config.py               # Loads config.conf into a Python dict (mirror config.sh)
├── requirements.txt        # flask, gunicorn (keep minimal; stdlib for the rest)
├── bridge/
│   ├── __init__.py
│   ├── engine.py           # Subprocess wrappers around src/*.sh functions
│   ├── ollama.py           # Direct Python client for /api/generate streaming
│   └── rag_db.py           # Read-only queries against .cache_vetorial/rag_store.db
├── db/
│   ├── chat.py             # CRUD for chat history DB (web app's own SQLite)
│   └── schema.sql          # Chat/session/document-meta tables
├── routes/
│   ├── chat.py             # /api/chat (SSE), /api/sessions
│   ├── settings.py         # GET/POST config.conf, prompt template
│   └── documents.py        # /api/sync, /api/documents
├── templates/
│   ├── base.html           # Jinja layout: sidebar + main pane
│   ├── chat.html           # Chat view
│   └── settings.html       # Settings + prompt editor
├── static/
│   ├── css/app.css         # Single stylesheet (retro-green accent to match brand)
│   └── js/
│       ├── chat.js         # SSE consumer, message rendering, source pills
│       ├── sessions.js     # History sidebar
│       └── settings.js
└── tests/
    ├── test_bridge.py
    ├── test_routes.py
    └── test_db.py
```

Run from repo root so relative paths (`./.cache_vetorial`, `PASTA_ALVO`) resolve identically to the CLI. `web/data/chat_history.db` holds GUI state, kept separate from the RAG vector store.

## Backend Integration

The cleanest bridge is to **source the modules and call one function** per request. Add a tiny non-interactive entrypoint `src/rag_query.sh` that sources `config.sh ai.sh vector.sh ingest.sh`, then runs: `gerar_embedding` → `buscar_trechos_relevantes` → prompt assembly → `perguntar_ollama`. It emits tokens to stdout and structured source metadata (file paths from the retrieved chunks) to a separate channel (e.g. a `[[SOURCES]]{json}` sentinel line, or stderr).

`bridge/engine.py` responsibilities:
- **`stream_answer(query, session_history)`** — spawns `rag_query.sh` via `subprocess.Popen(..., stdout=PIPE, bufsize=1)` and yields decoded tokens line-by-line for SSE. Parses the sources sentinel and yields a final `sources` event.
- **`sync_documents()`** — runs `ingest.sh::sincronizar_documentos` (long-running; stream progress lines to the UI).
- **`get_config()` / `set_config(key, value)`** — read/write `config.conf` (reuse `atualizar_configuracao` semantics; parse the simple `KEY="value"` format in Python).

**Important:** the current `perguntar_ollama` prompts interactively via `/dev/tty` on a missing model and prints ANSI colors. For web use, add a `NON_INTERACTIVE=1` env guard that skips the `read` prompts and disables color codes so raw tokens reach the browser. This is the single required change to the existing shell.

**Phase 2 optimization:** port `buscar_trechos_relevantes`' cosine search from the `jq` implementation to `rag_db.py` (NumPy or pure Python dot-product over rows), and call Ollama's streaming endpoint directly from `bridge/ollama.py`. This removes per-request subprocess/jq overhead while keeping `config.conf`, ingestion, and the vector store untouched. The process-number acervo filter (regex `[0-9]{4}\.?[0-9]{10}`) must be preserved.

## Frontend Components

Server-rendered Jinja shell + progressive JS; no framework, no bundler.

- **Layout (`base.html`):** left sidebar = chat session list + "New chat" + "Sync docs"; main pane = message stream + input box; top-right = settings gear.
- **Streaming (`chat.js`):** POST the query, open an `EventSource` to `/api/chat/stream?session_id=...`. Append `token` events to the live assistant bubble; on the `sources` event, render clickable source "pills" (file name + chunk) beneath the answer; `done` event closes the stream and persists the message. SSE is preferred over WebSocket — responses are unidirectional token streams and SSE auto-reconnects with far less code.
- **Prompt editor + settings (`settings.html`):** textarea for the system/RAG prompt template, and form fields bound to `config.conf` keys (`MODELO_IA`, `MODELO_EMBEDDING`, `TEMPERATURA`, `CHUNK_SIZE`, `CHUNK_OVERLAP`, `PASTA_ALVO`). Save via `POST /api/settings`.
- **Document UI (`documents.html`/panel):** list indexed files (`SELECT DISTINCT caminho_arquivo FROM document_chunks`), show chunk counts, and a "Sincronizar" button that streams ingest progress.

## Database Schema

GUI-owned SQLite (`web/data/chat_history.db`), distinct from the vector store:

```sql
CREATE TABLE sessions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT,                         -- derived from first user message
    created_at   TEXT DEFAULT (datetime('now')),
    updated_at   TEXT DEFAULT (datetime('now'))
);

CREATE TABLE messages (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id   INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    role         TEXT NOT NULL CHECK (role IN ('user','assistant','system')),
    content      TEXT NOT NULL,
    sources      TEXT,                          -- JSON array of {caminho, chunk_index}
    created_at   TEXT DEFAULT (datetime('now'))
);

CREATE TABLE settings (                          -- prompt template + UI prefs
    key          TEXT PRIMARY KEY,
    value        TEXT
);
CREATE INDEX idx_messages_session ON messages(session_id);
```

Document metadata is **read from the existing `rag_store.db`** — no duplication. The `settings` table stores only web-specific state (prompt template, model params still live in `config.conf` as source of truth).

## Testing

- **Unit (`pytest`):** `test_bridge.py` mocks `subprocess`/Ollama to verify token parsing and source-sentinel extraction; `test_db.py` covers session/message CRUD against a temp SQLite.
- **Integration:** Flask `test_client` hits `/api/chat/stream` and asserts SSE event sequence (`token*` → `sources` → `done`); `/api/settings` round-trips `config.conf`.
- **Shell contract:** `bats` (or a smoke script) asserts `rag_query.sh` with `NON_INTERACTIVE=1` emits clean, color-free tokens and a valid sources line — guarding the bridge boundary.
- **E2E:** Playwright drives new chat → streamed answer → source pills → history reload, against a seeded vector store and a small Ollama model.

## Deployment

Development: `flask --app web/app run --debug` (single worker; SSE works fine).

Production: **Gunicorn** with `gevent`/`sync` workers behind the local host — SSE needs `--timeout 0` (or a long timeout) and worker types that don't buffer streaming responses; long-lived subprocess streams favor a threaded/async worker. Bind to `127.0.0.1` only (air-gapped). Provide a `systemd` unit or a `run_web.sh` launcher that `cd`s to repo root, exports `NON_INTERACTIVE=1`, and starts Gunicorn. Ollama and `sqlite3`/`jq`/`pdftotext` remain host dependencies (already required by the CLI). No reverse proxy needed for single-user local use; add nginx only if remote/multi-user access is later required.

## Implementation Order

1. `rag_query.sh` non-interactive entrypoint + `NON_INTERACTIVE` guard in `ai.sh`.
2. `bridge/engine.py` subprocess streaming + chat SSE route.
3. Chat DB schema + session/message persistence.
4. Frontend chat view with SSE and source pills.
5. Settings/prompt editor + document sync UI.
6. Tests, then Gunicorn/systemd packaging.
7. Phase 2: port cosine search + Ollama client to Python for latency.

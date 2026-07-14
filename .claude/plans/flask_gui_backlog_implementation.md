# Flask GUI Backlog Implementation Roadmap

**Planned by**: Fable planning agent  
**Date**: 2026-07-14  
**Target**: AI-RAGJus Flask web GUI (Phase 1 → Phase 2)

## Overview

Implementation plan for four backlog features:
1. Lazy-load chat list (pagination + infinite scroll)
2. Chat context menu (rename + delete with cascade)
3. Per-chat memory (session-level context extraction & injection)
4. Global memory (cross-session learning + inspector UI)

## Current State Analysis

**Existing infrastructure:**
- `web/db.py` has unused `update_session_title()` and working `DELETE /api/sessions/<id>` with `PRAGMA foreign_keys = ON` + `ON DELETE CASCADE`
- `init_db()` runs `CREATE TABLE IF NOT EXISTS` on every startup → **no migration tooling needed** for new tables
- `requests==2.31.0` already in `web/requirements.txt` (can call Ollama directly from Python)
- Sidebar currently dual-rendered: Jinja loop + JS `refreshSessionList()` (duplication to consolidate in M1)
- Prompt assembly in bash (`src/rag_query.sh`, step 5), not Python → **cross-cutting dependency on memory injection**

---

# Milestone 0 — Shared Plumbing: Memory Context Injection

**Prerequisite for features 3 & 4. Must land first.**

## Change

Modify `src/rag_query.sh` to read optional env var `RAG_MEMORY_CONTEXT`. If non-empty, insert a block into the prompt between "Metadados do Acervo Local" and "Documentos Jurídicos de Contexto":

```
Contexto de Memória (fatos conhecidos desta conversa e do usuário):
$RAG_MEMORY_CONTEXT
```

### Rationale

- Env var (not script arg) avoids quoting pitfalls and keeps CLI contract unchanged
- Also add to empty-context branch of prompt
- In `web/app.py::api_chat`, set `env["RAG_MEMORY_CONTEXT"]` before `subprocess.Popen`

## Files

- `src/rag_query.sh` — add memory block to prompt template
- `web/app.py::api_chat` — export `RAG_MEMORY_CONTEXT` env before subprocess

## Effort

**S** (Small)

## Testing

Shell contract: smoke-run with `RAG_MEMORY_CONTEXT="fato teste" bash src/rag_query.sh "pergunta"` and verify prompt includes the memory block (or add `DEBUG_PROMPT=1` guard for testing).

---

# Milestone 1 — Lazy-Load Chat List

**Independent. Can start immediately.**

## Schema

None.

## Backend

### `web/db.py`

- **New function**: `list_sessions(limit=30, offset=0)` — add `LIMIT ? OFFSET ?` to existing query; return `{"sessions": [...], "has_more": bool}` (or fetch `limit+1` rows to compute `has_more`).
- Return `COUNT(*)` total or just the `has_more` boolean.

### `web/app.py`

- **New route**: `GET /api/sessions?limit=&offset=` — validate/clamp params (max 100).
  - Response: `{"sessions": [...], "has_more": true}` (breaking change from bare array — must ship atomically with JS update).
- **Modify `index()` route**: stop calling `db.list_sessions()`; render shell only.

## Frontend

### `web/templates/chat.html`

- Replace Jinja `{% for s in sessions %}` loop with a spinner placeholder:
  ```html
  <div class="session-loading">
    <div class="spinner"></div>
  </div>
  ```
  This removes server-render/JS duplication.

### `web/static/chat.js`

- On `DOMContentLoaded`, fetch page 0 (`GET /api/sessions?offset=0`).
- Append a sentinel `<div>` at list bottom watched by an `IntersectionObserver` that triggers page 2 fetch.
- After a chat turn, `refreshSessionList()` resets to page 0 (new/updated sessions sort first by `updated_at DESC`).
- **Note**: Virtual scrolling is overkill for single-user local tool; pagination + infinite scroll suffices.

### `web/static/style.css`

- Spinner keyframes + `.session-loading` styles.

## Testing

- **pytest** (`web/tests/test_sessions.py`): seed 75 sessions in temp DB, assert page boundaries, `has_more` flag, ordering, param clamping.
- **E2E** (webapp-testing/Playwright): load page → assert spinner appears → sessions render → scroll to trigger page 2.

## Effort

**S** (Small)

## Dependencies

None.

---

# Milestone 2 — Chat Context Menu (Rename / Delete)

**Depends on M1 (shares session-item JS renderer).**

## Schema

None.

## Backend

### `web/app.py`

- **New route**: `PATCH /api/sessions/<int:session_id>` — accept `{"title": "..."}`, validate non-empty + max ~120 chars, return 404 if missing.
  - Calls existing `db.update_session_title()`.
- **Modify `DELETE /api/sessions/<id>`**: add 404 guard for nonexistent ids (currently silently returns ok).

## Frontend

### HTML Structure (from M1 JS renderer)

Change session item from single `<button>` to:
```html
<div class="session-item">
  <span class="session-title">Chat title</span>
  <button class="session-menu-btn">⋮</button>
</div>
```

(Nested buttons are invalid HTML; single button won't hold a menu.)

### `web/static/chat.js`

- Create/destroy **one shared dropdown menu** (absolutely positioned), close on outside-click/Escape.
- Menu items: "Renomear" + "Excluir".

**Rename UX:**
- Click "Renomear" → swap `<span class="session-title">` for an `<input>`, focus.
- Commit on Enter/blur: `PATCH /api/sessions/<id>` with new title.
- Cancel on Escape.
- Simpler than modal; matches ChatGPT.

**Delete UX:**
- Click "Excluir" → inline confirmation dialog ("Excluir?" / "Cancelar" replacing the menu).
- Confirm → `DELETE /api/sessions/<id>` → remove node from sidebar.
- If it was `currentSessionId`, reset to new-chat state.

### `web/static/style.css`

- Menu styling, input inline-edit styles, confirmation dialog styles.

## Testing

- **pytest**: PATCH validation (non-empty, max length, 404s), DELETE 404s, cascade check (assert `messages` rows deleted).
- **E2E**: rename persists across reload; delete removes from sidebar + clears pane.

## Effort

**M** (Medium) — mostly JS/CSS.

## Dependencies

M1 (shared session-item renderer; delete also cleans session_memory via cascade).

---

# Milestone 3 — Per-Chat Memory

**Depends on M0 (RAG_MEMORY_CONTEXT hook). Independent of M1/M2.**

## Schema

Append to `SCHEMA` in `web/db.py`:

```sql
CREATE TABLE IF NOT EXISTS session_memory (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    content     TEXT NOT NULL,
    created_at  TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_session_memory_session ON session_memory(session_id);
```

**Rationale**: Separate table beats `memory` column:
- Multiple discrete facts per session
- Individual fact pruning
- Free cascade on session delete (integrates with M2)
- Avoids `ALTER TABLE` (only `CREATE TABLE IF NOT EXISTS` needed)

## Backend

### `web/db.py`

- `add_session_memory(session_id, content)` — insert row
- `get_session_memory(session_id, limit=10)` — fetch recent facts
- `prune_session_memory(session_id, keep=10)` — delete oldest beyond cap

### New module: `web/memory.py`

**`extract_facts(query, answer, config)`**
- Non-streaming POST to `{OLLAMA_URL}/api/generate`
- Prompt (Portuguese): "Extraia até 3 fatos objetivos e curtos desta interação, um por linha; responda SOMENTE com os fatos ou 'NENHUM'"
- `temperature 0`, short timeout (~30s)
- Swallow errors (memory is best-effort; mirrors napkin rule: inference failure never breaks main flow)
- Parse response: split by lines, filter empty, ignore "NENHUM"

**`build_memory_context(session_id)`**
- Fetch session facts + apply cap (~1500 chars) to protect small model context window
- Returns formatted block for `RAG_MEMORY_CONTEXT` env var

### `web/app.py::api_chat`

**Before spawn:**
```python
env["RAG_MEMORY_CONTEXT"] = memory.build_memory_context(session_id)
```

**After stream finishes:**
- Once `full_answer` is persisted to DB
- Fire extraction in `threading.Thread(daemon=True)` so SSE `done` event isn't delayed
- Trade-off: Flask dev server with `threaded=True` is fine; future Gunicorn config must use threaded workers

## Frontend

**Optional mini-UI** (can ship backend-only first):
- Small "memória da conversa" disclosure in chat header
- Show current facts
- Per-fact delete button
- Endpoint: `GET /api/sessions/<id>/memory`

## Testing

- **pytest**:
  - Mock `requests.post` for Ollama calls
  - `extract_facts` parses lines, handles "NENHUM", handles timeout gracefully
  - `build_memory_context` caps output, joins facts
  - Prune-cap test
  - Assert `RAG_MEMORY_CONTEXT` in subprocess env by inspecting mocked `subprocess.Popen`

- **Shell contract**: smoke-run `RAG_MEMORY_CONTEXT="fato teste" bash src/rag_query.sh "pergunta"` and verify memory block in prompt (or add `DEBUG_PROMPT=1` guard).

## Effort

**M–L** (Medium to Large)

## Dependencies

M0 (RAG_MEMORY_CONTEXT hook).

---

# Milestone 4 — Global Memory + Settings Inspector Page

**Depends on M0 + M3 (shares `memory.py` extraction logic). Lands together with M3 for cohesion.**

## Schema

Append to `SCHEMA` in `web/db.py`:

```sql
CREATE TABLE IF NOT EXISTS global_memory (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    key         TEXT NOT NULL UNIQUE,
    value       TEXT NOT NULL,
    source      TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','auto')),
    enabled     INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT DEFAULT (datetime('now')),
    updated_at  TEXT DEFAULT (datetime('now'))
);
```

**Rationale:**
- `source`: distinguish auto-learned (from extraction) vs user-entered
- `enabled`: toggle injection without deleting
- UNIQUE key: one fact per key (upsert semantics)

## Backend

### `web/db.py`

- `list_global_memory()` — fetch all, return `{"enabled": [...], "disabled": [...]}`
- `upsert_global_memory(key, value, source='manual')` — insert or update
- `set_global_memory_enabled(id, enabled)` — toggle without deletion
- `delete_global_memory(id)` — remove entry

### `web/app.py` Routes

- `GET /settings` — render settings page (Jinja template)
- `GET /api/memory/global` — return all entries
- `POST /api/memory/global` — create new entry (validate key ~20 chars, value ~500 chars)
- `PATCH /api/memory/global/<id>` — edit entry
- `DELETE /api/memory/global/<id>` — delete entry

### `web/memory.py` Extension

**Update `build_memory_context(session_id)`:**
- Prepend enabled global entries (`- {key}: {value}`)
- Cap global separately (~800 chars) from session facts (~1500 chars total)
- Phase 1: inject **all enabled** entries (adequate for single-user manual curation)
- Phase 2 (note in code): embed keys + cosine-select top-k per query once vector search ported to Python

**Auto-populate extension:**
- In the `extract_facts` background thread, add a second extraction prompt: "Preferências ou fatos de longo prazo sobre o usuário/domínio; responda 'NENHUM' se for específico desta conversa"
- Upsert with `source='auto'`
- Cap auto entries (e.g., 30); evict oldest when cap reached
- Disable feature via config flag if user prefers manual-only (e.g., `AUTO_MEMORY=0`)

## Frontend

### New `web/templates/settings.html`

- Extends `base.html`
- **Config display** (read-only): show `config.conf` values (reuse `load_config()`)
  - MODELO_IA, MODELO_EMBEDDING, TEMPERATURA, CHUNK_SIZE, CHUNK_OVERLAP, PASTA_ALVO
  - (Actual editing of these can come later; this is read-only reference)
- **Memória Global Inspector** table:
  - Columns: key | value | source (badge) | enabled (toggle) | actions (edit, delete)
  - "Add new" form below: key field + value textarea
  - Inline edit (swap row to edit mode on pencil-click)
  - Delete with confirm

### `web/static/settings.js`

- Form validation (key non-empty, reasonable length)
- Toggle enabled state (immediate `PATCH`)
- Delete confirm dialogs
- Inline edit mode toggle

### UI Integration

- Gear icon in `chat.html` sidebar footer links to `/settings`
- New `web/static/style.css` entries: table styling, form inputs, toggle switch, confirm dialogs

## Testing

- **pytest**:
  - CRUD round-trips (create, read, update, delete)
  - Unique-key constraint + upsert behavior
  - Enabled filtering in `build_memory_context`
  - Assert disabled entries excluded from injection
  - Auto-populate thread: mock extraction, assert `source='auto'` cap

- **E2E** (Playwright):
  - Add a fact ("usuário atua em direito trabalhista")
  - Send a chat
  - Verify fact appears in `RAG_MEMORY_CONTEXT` (mock/instrument subprocess env)
  - Toggle off
  - Send another chat
  - Verify fact excluded from memory context

## Effort

**L** (Large) — new page, full CRUD UI, auto-extraction, settings integration.

## Dependencies

M0 + M3 (shares `memory.py`, extraction thread, env var injection).

---

# Implementation Sequencing

```
M0 (S)  ──► M3 (M–L) ──┐
           ┌────────────┤
           │            └──► M4 (L) global memory + settings
           │
M1 (S) ────► M2 (M) context menu
```

**Parallel pairs:**
- M0 and M1 can start simultaneously (independent)
- M3 and M1/M2 can run in parallel (only M3 depends on M0)

**Recommended order** (to ship UX wins first, maximize parallelism):
1. **M1** — Lazy-load (small, high-visibility, unblocked)
2. **M2** — Context menu (small, requires M1 renderer)
3. **M0** — RAG_MEMORY_CONTEXT hook (small, unblocks M3/M4)
4. **M3** — Per-chat memory (medium, core logic)
5. **M4** — Global memory + settings (large, lands with M3 for cohesion)

Alternatively, if you want to ship memory features together first: **M0 → M3 → M4 → M1 → M2** (all features production-ready; UI polish last).

## Total Effort Estimate

| Milestone | Effort | Notes |
|-----------|--------|-------|
| M0 | S | Bash + 1 Python line |
| M1 | S | Consolidates sidebar rendering |
| M2 | M | Mostly JS/CSS (menu, inline edit) |
| M3 | M–L | Extraction thread, context injection |
| M4 | L | Settings page, CRUD UI, auto-population |
| **Total** | ~2S + 2M/M-L + 1L | ~3–4 sprints for one developer |

---

# Critical Implementation Notes

## File Checklist

- [ ] `/home/lw_na/git/ai-ragjus/src/rag_query.sh` — add memory block to prompt (M0)
- [ ] `/home/lw_na/git/ai-ragjus/web/app.py` — routes, env injection, background thread, SSE (M0, M1, M2, M3, M4)
- [ ] `/home/lw_na/git/ai-ragjus/web/db.py` — schema additions, pagination, CRUD helpers (M1, M2, M3, M4)
- [ ] `/home/lw_na/git/ai-ragjus/web/memory.py` — **new file** (M3, M4)
- [ ] `/home/lw_na/git/ai-ragjus/web/static/chat.js` — lazy-load, session-item renderer, context menu, inline rename (M1, M2)
- [ ] `/home/lw_na/git/ai-ragjus/web/templates/chat.html` — spinner, settings link (M1, M2)
- [ ] `/home/lw_na/git/ai-ragjus/web/templates/settings.html` — **new file** (M4)
- [ ] `/home/lw_na/git/ai-ragjus/web/static/settings.js` — **new file** (M4)
- [ ] `/home/lw_na/git/ai-ragjus/web/static/style.css` — spinner, menu, inline-edit, settings table styles (M1–M4)

## Risks

1. **Context-window pressure**: Default model is `qwen2.5:1.5b`. Char caps in `build_memory_context` are load-bearing.
   - Monitor prompt length; log to stderr if approaching limit.
   - Phase 2: summarize old facts, compress before injection.

2. **SQLite single-writer lock**: Background extraction thread writes while new chat turn may write.
   - Current `get_conn()` uses short-lived connections (good).
   - **Add `PRAGMA busy_timeout = 5000` to `get_conn()`** as cheap insurance.

3. **Atomic response-shape change** (M1): `/api/sessions` response changes from bare array to `{"sessions": [...], "has_more": bool}`.
   - Must ship `chat.js` update in **same commit**.
   - Add integration test to catch this.

4. **Gunicorn worker config** (M3 background thread):
   - Dev server: `flask --app web/app run --debug` (threaded=True by default) works.
   - Production: Future Gunicorn config must use **threaded or async workers** (not `sync`), or move extraction off-thread to a job queue.
   - Document this constraint; consider `rq` (Redis queue) for Phase 2 if scaling.

5. **Browser history/UX**: After rename/delete via 3-dots menu, back-button behavior may be confusing.
   - Test in E2E; consider disabling history.pushState if it causes issues.

## Phase 2 Optimizations (Future)

- **M3/M4 Fast-path**: Replace `memory.extract_facts` extraction prompt with a lightweight embedding-based summary (embed facts, store vectors, reuse existing vector DB).
- **M4 Smart injection**: Embed query + cosine-select top-k global facts instead of injecting all enabled.
- **M3 Auto-facts compression**: Summarize old facts to free context window.
- **Background queue**: Move extraction thread to `rq` + Redis (or similar) to decouple from Flask request/response cycle.

---

# Testing Checklist

- [ ] M0: Shell smoke test — `RAG_MEMORY_CONTEXT="fato" bash src/rag_query.sh "q"` includes memory block
- [ ] M1: pytest pagination (boundaries, has_more, sorting); E2E infinite scroll trigger
- [ ] M2: pytest rename/delete validation; E2E persist across reload + cascade cleanup
- [ ] M3: pytest fact extraction parsing + context capping; E2E memory injected into `RAG_MEMORY_CONTEXT`
- [ ] M4: pytest CRUD + enabled filtering; E2E settings page CRUD + auto-populate; verify injection
- [ ] Integration: `/api/sessions` response-shape atomicity with `chat.js` update
- [ ] Performance: log extraction latency (should be ~30s total for 2 prompts); profile sidebar render with 100+ sessions

---

# Sign-Off

Plan is implementation-ready. All file paths, schema changes, endpoint contracts, and UI specs are concrete. Recommended start: **M1** (visible UX win, unblocked, consolidates sidebar logic).

**Questions for stakeholder:**
1. Prefer sequential (one feature done fully before next) or parallel (multiple in flight)?
2. Auto-memory population (M4): on by default, or opt-in?
3. Phase 2 timeline for vector-based fact selection + job queue?

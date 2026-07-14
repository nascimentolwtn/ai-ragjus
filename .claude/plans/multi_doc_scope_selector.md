---
title: Multi-Doc Scope Selector (NotebookLM-style Document Focus)
date: 2026-07-14
status: draft
related:
  - flask_gui_design.md
  - flask_gui_backlog_implementation.md
  - flask_gui_context_window_monitor.md
  - ragsec_company_variant.md
---

# Multi-Doc Scope Selector (NotebookLM-style)

## Executive Summary

This feature lets a user pin a subset of indexed documents to a chat session, so RAG
retrieval only searches within those documents — the same "source selection" model
NotebookLM uses. A sidebar folder tree with checkboxes (Flask GUI) lets the user pick
documents; the selection is stored per session in `web/data/chat_history.db`; and the
Bash search layer (`src/vector.sh`) filters the SQLite similarity query to the selected
paths. This enables focused analysis (e.g., one contract plus its amendments) without
noise from the rest of the corpus.

The backend already supports this cheaply: `sincronizar_pasta()` scans subfolders
recursively and stores full absolute paths in `document_chunks.caminho_arquivo`
(indexed via `idx_caminho`), so scoping reduces to an additional `WHERE` condition —
which also shrinks the JSON payload fed to the jq cosine-similarity pass, making scoped
queries *faster* than full-corpus queries. No changes to the vector store schema, the
CLI, or ingestion are required; the CLI remains scope-unaware and unaffected.

---

## Review Findings (issues found in the original draft — fixed below)

| # | Severity | Finding | Resolution in this plan |
|---|----------|---------|-------------------------|
| 1 | High | Draft's scope filter interpolated raw paths into SQL (`caminho_arquivo = '$doc_path'`). Real paths in this DB contain spaces and special characters (e.g. `/Applications/SERVER/ - AI PROJTEMP/...`); a path with an apostrophe breaks the query. | Escape single quotes jq-side (`gsub("'";"''")`) when building the `IN (...)` list, mirroring the existing `salvar_bloco_vetorial()` escaping pattern (`src/vector.sh:132`). |
| 2 | High | Draft's "simpler alternative" built SQL string literals with **double quotes** via jq. In SQLite, double quotes denote identifiers; string literals need single quotes. Fragile / incorrect. | Rejected. Single-quoted, escaped `IN` list only. |
| 3 | High | Scope is keyed to `session_id`, but `/api/chat` creates sessions **lazily on first message** (`web/app.py:124-129`). There is no `POST /api/sessions` endpoint today, so there is nothing to attach a scope to before the first message. | Add explicit `POST /api/sessions` (create empty session) so the UI can create a session, set scope, then chat. Also accept `selected_docs` inline in the first `/api/chat` payload as a fallback. |
| 4 | High | Draft never showed how `/api/chat` passes the scope to the subprocess. | `api_chat()` loads the session scope and sets `env["SCOPE_DOCS"] = json.dumps(paths)` before `subprocess.Popen`. Environment variable only — the draft's `$2` positional arg in `rag_query.sh` is dropped (redundant second channel). |
| 5 | Medium | Draft hardcoded `.cache_vetorial` in the tree endpoint. `CACHE_DIR` is configurable in `config.conf` and already parsed by `load_config()` (`web/app.py:56`). | Resolve the vector DB path from `load_config()["CACHE_DIR"]`. |
| 6 | Medium | Paths in `document_chunks` are absolute. Grouping the tree by full parent path yields unusable labels like `/Applications/SERVER/ - AI PROJTEMP/ai-jus-rag-app/docs/processos`. | Display paths relative to `PASTA_ALVO`; keep the absolute path as the checkbox value (it must match the DB exactly). |
| 7 | Medium | `buscar_trechos_relevantes()` already auto-injects a process-number filter (`src/vector.sh:153-169`), AND-combined with other conditions. A scoped session + a question mentioning a process number outside the scope silently returns zero chunks. | When `SCOPE_DOCS` is set, skip the auto process-number filter — an explicit user selection outranks a heuristic. |
| 8 | Medium | `rag_query.sh` injects corpus metadata into the prompt (`total_arquivos`, `arquivos_nomes`, lines 64-66) computed over the **whole** DB. In a scoped session the model would be told about documents it cannot cite. | When `SCOPE_DOCS` is set, compute those stats over the scoped set. |
| 9 | Low | Draft's `session_doc_scope` insert would violate `UNIQUE(session_id)` on the second save, and `updated_at` would never change. | Upsert with `ON CONFLICT(session_id) DO UPDATE ... updated_at = datetime('now')`. |
| 10 | Low | Semantics of "empty selection" undefined. | No scope row, `NULL`, or empty array all mean **all documents** (backward compatible). The UI disables "apply" on an empty selection instead of persisting it. |
| 11 | Low | Stale scope after re-sync: a scoped path may vanish from `document_chunks` (file removed/renamed). Search degrades gracefully (fewer/zero rows) but the user gets no signal. | Tree endpoint returns the live doc list; the JS marks scoped-but-missing docs with a warning style and the pills show a `!` badge. |

---

## Architecture

```
┌─ Browser ─────────────────────────────────────────────────────┐
│ sidebar folder tree (checkboxes)      scope pills in header   │
│        │ POST /api/sessions/<id>/scope        ▲               │
└────────┼──────────────────────────────────────┼───────────────┘
         ▼                                      │
┌─ Flask web/app.py ────────────────────────────┴───────────────┐
│ /api/documents/tree   → reads rag_store.db (read-only)        │
│ /api/sessions (POST)  → create empty session (new)            │
│ /api/sessions/<id>/scope (GET/POST) → web/db.py               │
│ /api/chat → env SCOPE_DOCS='["/abs/a.pdf",...]' ──────────┐   │
└───────────────────────────────────────────────────────────┼───┘
                                                            ▼
┌─ Bash engine ─────────────────────────────────────────────────┐
│ src/rag_query.sh  (reads $SCOPE_DOCS, scopes prompt metadata) │
│ src/vector.sh:buscar_trechos_relevantes()                     │
│   → condicoes+=("caminho_arquivo IN ('…','…')")               │
│   → SQLite pre-filter → jq cosine similarity on fewer rows    │
└───────────────────────────────────────────────────────────────┘
```

Key properties:

- **Scope lives in the GUI DB** (`web/data/chat_history.db`), never in the vector store.
  The CLI and RAGSEC builds are untouched.
- **Filtering happens in SQLite**, before the jq cosine pass — combining naturally (AND)
  with the existing `condicoes` array, including the RAGSEC clearance filter
  (`src/vector.sh:172-176`).
- **Transport is a single environment variable** (`SCOPE_DOCS`, JSON array of absolute
  paths). No shell-quoting hazards: Python `json.dumps` → env → jq parses it.

---

## 1. Schema Changes (`web/db.py`)

Append to the `SCHEMA` string (idempotent, additive — existing sessions unaffected):

```sql
-- Selected document paths per session (absent row = all documents)
CREATE TABLE IF NOT EXISTS session_doc_scope (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id         INTEGER NOT NULL UNIQUE REFERENCES sessions(id) ON DELETE CASCADE,
    selected_docs_json TEXT NOT NULL,          -- JSON array of absolute paths
    total_available    INTEGER,                -- corpus size at selection time (UI breakdown)
    created_at         TEXT DEFAULT (datetime('now')),
    updated_at         TEXT DEFAULT (datetime('now'))
);

-- Optional audit trail of scope edits (Phase 3; useful with RAGSEC audit log)
CREATE TABLE IF NOT EXISTS scope_changes (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id    INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    old_docs_json TEXT,
    new_docs_json TEXT,
    changed_at    TEXT DEFAULT (datetime('now'))
);
```

`ON DELETE CASCADE` works because `get_conn()` already enables
`PRAGMA foreign_keys = ON` (`web/db.py:47`).

### DB helpers (new functions in `web/db.py`)

```python
def get_session_scope(session_id):
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
    """Empty list clears the scope row (= back to all documents)."""
    with get_conn() as conn:
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
            conn.execute(
                "DELETE FROM session_doc_scope WHERE session_id = ?", (session_id,)
            )
            return
        conn.execute(
            "INSERT INTO session_doc_scope (session_id, selected_docs_json, total_available) "
            "VALUES (?, ?, ?) "
            "ON CONFLICT(session_id) DO UPDATE SET "
            "  selected_docs_json = excluded.selected_docs_json, "
            "  total_available    = excluded.total_available, "
            "  updated_at         = datetime('now')",
            (session_id, json.dumps(selected_docs, ensure_ascii=False), total_available),
        )
```

---

## 2. Backend: Scoped Search

### A. `src/rag_query.sh` — consume `SCOPE_DOCS`, scope the prompt metadata

`SCOPE_DOCS` arrives via the environment (set by Flask); no argv change needed.
Validate it defensively, then scope the corpus stats that feed the prompt
(currently lines 64-66 compute them over the whole DB):

```bash
# After carregar_configuracoes: sanitize SCOPE_DOCS (must be a JSON array of strings)
if [ -n "${SCOPE_DOCS:-}" ]; then
    if ! echo "$SCOPE_DOCS" | jq -e 'type == "array" and all(type == "string")' >/dev/null 2>&1; then
        unset SCOPE_DOCS   # malformed → fall back to full corpus, never crash
    fi
fi
```

```bash
# Replace the corpus-metadata block (steps 4b): scope-aware stats
db_path=$(obter_db_path)
if [ -n "${SCOPE_DOCS:-}" ]; then
    scope_in=$(echo "$SCOPE_DOCS" | jq -r "map(\"'\" + gsub(\"'\"; \"''\") + \"'\") | join(\",\")")
    total_arquivos=$(sqlite3 "$db_path" "SELECT COUNT(DISTINCT caminho_arquivo) FROM document_chunks WHERE caminho_arquivo IN ($scope_in);" 2>/dev/null || echo "0")
    arquivos_nomes=$(sqlite3 "$db_path" "SELECT DISTINCT caminho_arquivo FROM document_chunks WHERE caminho_arquivo IN ($scope_in);" 2>/dev/null | awk -F/ '{print $NF}' | sort -u | paste -sd ", " - || echo "")
else
    total_arquivos=$(sqlite3 "$db_path" "SELECT COUNT(DISTINCT caminho_arquivo) FROM document_chunks;" 2>/dev/null || echo "0")
    arquivos_nomes=$(sqlite3 "$db_path" "SELECT DISTINCT caminho_arquivo FROM document_chunks;" 2>/dev/null | awk -F/ '{print $NF}' | sort -u | paste -sd ", " - || echo "")
fi
```

`buscar_trechos_relevantes` needs no new parameter — it inherits `SCOPE_DOCS` from the
environment (it is already exported by Flask into the subprocess env; `export` in bash
is unnecessary for a var already in the process environment).

### B. `src/vector.sh:buscar_trechos_relevantes()` — scope condition

Insert into the existing filter block. The `condicoes` array (line 152) already merges
conditions with AND (lines 178-183), so RAGSEC clearance composes correctly.
Note the process-number heuristic becomes an `elif` — explicit scope wins:

```bash
    local condicoes=()

    # Escopo explícito de documentos (sessão da GUI web). Quando ativo,
    # substitui o filtro heurístico por número de processo: a seleção
    # manual do usuário tem precedência sobre a inferência automática.
    local scope_in=""
    if [ -n "${SCOPE_DOCS:-}" ]; then
        # jq escapa aspas simples ('' ) e monta a lista IN com literais seguros
        scope_in=$(echo "$SCOPE_DOCS" | jq -r "map(\"'\" + gsub(\"'\"; \"''\") + \"'\") | join(\",\")" 2>/dev/null || echo "")
    fi

    if [ -n "$scope_in" ]; then
        condicoes+=("caminho_arquivo IN ($scope_in)")
        echo -e "${YELLOW}[Escopo de Documentos Ativo: $(echo "$SCOPE_DOCS" | jq 'length') doc(s) selecionado(s)]${NC}" >&2
    elif [ -n "$query_original" ]; then
        # ... bloco existente do filtro por número de processo (linhas 153-169), inalterado ...
    fi
```

Why this is safe:
- Paths come from `document_chunks` itself (round-tripped through the tree endpoint),
  not free-form user text.
- `gsub("'";"''")` is the standard SQLite escape, identical in effect to the `sed`
  escaping already used in `salvar_bloco_vetorial()`.
- Exact `IN` matching (not `LIKE`) — no wildcard surprises with spaces/dots in paths.

### C. `web/app.py:api_chat()` — plumb scope into the subprocess

```python
    # inside generate(), before Popen:
    env = os.environ.copy()
    env["NON_INTERACTIVE"] = "1"

    scope = db.get_session_scope(session_id)
    inline_docs = payload.get("selected_docs")          # first-message fallback (issue #3)
    if inline_docs and not scope:
        db.set_session_scope(session_id, inline_docs)
        scope = {"selected_docs": inline_docs}
    if scope and scope["selected_docs"]:
        env["SCOPE_DOCS"] = json.dumps(scope["selected_docs"], ensure_ascii=False)
```

---

## 3. API Endpoints (`web/app.py`)

### A. `POST /api/sessions` — explicit session creation (new; fixes issue #3)

```python
@app.route("/api/sessions", methods=["POST"])
def api_create_session():
    payload = request.get_json(silent=True) or {}
    title = (payload.get("title") or "Nova conversa").strip() or "Nova conversa"
    session_id = db.create_session(title)
    return jsonify({"ok": True, "session_id": session_id}), 201
```

### B. `GET /api/documents/tree` — folder/doc hierarchy from the vector store

```python
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
            rel = p.relative_to(pasta_alvo)      # display label (issue #6)
        except ValueError:
            rel = p                               # doc outside current PASTA_ALVO
        folder = str(rel.parent) if str(rel.parent) != "." else "raiz"
        tree.setdefault(folder, []).append({
            "name": rel.name,
            "path": filepath,                     # absolute — must match DB exactly
        })

    return jsonify({"folders": tree, "total": len(rows)})
```

Requires `import sqlite3` at the top of `web/app.py` (currently absent — it only uses
`web/db.py` for the GUI store). Read-only `SELECT DISTINCT` on an indexed column;
short-lived connection, negligible contention with the single-writer constraint.

### C. `GET`/`POST /api/sessions/<id>/scope`

```python
@app.route("/api/sessions/<int:session_id>/scope", methods=["GET"])
def api_get_session_scope(session_id):
    if not db.get_session(session_id):
        return jsonify({"error": "Sessão não encontrada."}), 404
    scope = db.get_session_scope(session_id)
    if not scope:
        return jsonify({"selected_docs": [], "total_available": None})
    return jsonify(scope)


@app.route("/api/sessions/<int:session_id>/scope", methods=["POST"])
def api_set_session_scope(session_id):
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
```

Validation note: paths are not free-form user input in practice (the UI round-trips
values from `/api/documents/tree`), and the bash side does proper SQL escaping anyway,
so path-existence validation is optional. Phase 3 may cross-check against the live doc
list to warn about stale paths (issue #11).

---

## 4. Frontend

### A. Sidebar folder tree — `web/templates/chat.html`

Insert after the "Nova conversa" button (line 13), before `#session-list`:

```html
<div class="scope-selector" id="scope-selector">
    <div class="scope-header">
        <h3>Documentos</h3>
        <button id="toggle-scope" class="toggle-scope-btn" type="button"
                title="Expandir/recolher" aria-expanded="true">&#9660;</button>
    </div>
    <div class="folder-tree" id="folder-tree">
        <!-- populated by chat.js from GET /api/documents/tree -->
    </div>
    <div class="scope-actions">
        <button id="select-all-docs" class="scope-action-btn" type="button">Selecionar todos</button>
        <button id="deselect-all-docs" class="scope-action-btn" type="button">Limpar</button>
    </div>
</div>
```

### B. Scope pills — chat header

Inside `<header class="chat-header">` (after the `<h1>`, line 35):

```html
<div class="scope-pills" id="scope-pills" title="Documentos no escopo desta conversa">
    <!-- e.g. "3 de 12 docs" + one pill per selected file -->
</div>
```

### C. JS behavior (`web/static/chat.js`)

New responsibilities (follows the existing IIFE/vanilla-JS style, `fetch` + SSE):

1. **Load tree on startup**: `GET /api/documents/tree` → render collapsible folders with
   checkboxes; folder checkbox toggles its children (tri-state via `indeterminate`).
2. **Apply scope**: on checkbox change (debounced ~300 ms):
   - If a session is active → `POST /api/sessions/<id>/scope`.
   - If no session yet → hold selection in a local `pendingScope` array; on first send,
     either `POST /api/sessions` first and then set scope, or attach
     `selected_docs: pendingScope` to the `/api/chat` body (fallback path, issue #3).
3. **Render pills**: after every scope change and on session switch
   (`GET /api/sessions/<id>/scope`), show `"N de M docs"` plus one pill per basename
   (`.split("/").pop()`, same pattern as the existing sources pills, `chat.js:72`).
   Empty scope → single pill "Todos os documentos".
4. **Session switch**: loading a session also loads its scope and syncs the checkboxes.
5. **Stale docs**: any scoped path absent from the tree response gets a `.scope-missing`
   class and a `!` badge on its pill (issue #11).
6. **Empty selection**: "Limpar" resets to all-docs (POSTs `[]`, which deletes the scope
   row). The tree never persists an empty *checked* state as "search nothing".

### D. CSS (`web/static/style.css`)

Reuse existing sidebar variables/dark-theme tokens. New classes: `.scope-selector`,
`.scope-header`, `.folder-tree`, `.folder-item`, `.doc-item`, `.scope-actions`,
`.scope-action-btn`, `.scope-pills`, `.scope-pill`, `.scope-missing`. Tree area gets
`max-height` + `overflow-y: auto` so long corpora don't push the session list off-screen.

---

## 5. Implementation Phases

| Phase | Scope | Deliverable | Depends on |
|-------|-------|-------------|------------|
| 1 | Backend filter | `SCOPE_DOCS` handling in `src/vector.sh` + `src/rag_query.sh`; manually testable via `SCOPE_DOCS='["/abs/path.pdf"]' NON_INTERACTIVE=1 bash src/rag_query.sh "pergunta"` | — |
| 2 | Persistence + API | `web/db.py` schema/helpers; `POST /api/sessions`; scope GET/POST; tree endpoint; `api_chat` env plumbing | 1 |
| 3 | Frontend | Sidebar tree, pills, JS wiring, CSS, stale-doc badges, `scope_changes` logging surfaced | 2 |

Phase 1 is independently valuable and verifiable from the CLI before any UI exists —
build and validate it first.

---

## 6. Testing

### Phase 1 (bash, no UI)

```bash
# Baseline (unscoped)
NON_INTERACTIVE=1 bash src/rag_query.sh "resumo do processo" | head -2

# Scoped to one real doc (take a path straight from the DB)
DOC=$(sqlite3 .cache_vetorial/rag_store.db "SELECT DISTINCT caminho_arquivo FROM document_chunks LIMIT 1;")
SCOPE_DOCS=$(jq -cn --arg d "$DOC" '[$d]') NON_INTERACTIVE=1 bash src/rag_query.sh "resumo" \
  | jq -r 'select(.type=="sources") | .content[].caminho' | sort -u
# EXPECT: only $DOC appears

# Scope to a nonexistent path → empty sources, "acervo vazio" prompt branch, no crash
SCOPE_DOCS='["/nao/existe.pdf"]' NON_INTERACTIVE=1 bash src/rag_query.sh "teste"

# Malformed SCOPE_DOCS → falls back to full corpus, no crash
SCOPE_DOCS='not-json' NON_INTERACTIVE=1 bash src/rag_query.sh "teste"

# Path containing a single quote (create a fixture doc named "o'brien.txt", sync, then scope to it)
```

### Phase 2 (API, curl)

- `POST /api/sessions` → 201 with `session_id`.
- `POST /api/sessions/<id>/scope` with 2 docs → `GET` echoes them; re-POST upserts
  (no UNIQUE violation); `POST []` deletes the row.
- `POST /api/sessions/999/scope` → 404. Non-list payload → 400.
- `/api/chat` on a scoped session → `sources` event only cites scoped docs.
- `GET /api/documents/tree` → folders relative to `PASTA_ALVO`, absolute `path` values.

### Phase 3 (UI, via webapp-testing/Playwright)

- Check 2 docs → pills show "2 de N"; send question → source pills ⊆ scope pills.
- New session starts unscoped; switching sessions swaps checkbox state.
- "Limpar" restores all-docs behavior; re-sync that removes a scoped doc shows the badge.
- Existing bats/e2e suites (`test/unit/`, `test/integration/run_e2e_suite.sh`) must still
  pass unchanged — scope off means zero behavior delta.

---

## 7. Risks & Open Questions

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| SQL breakage on exotic paths (quotes, spaces) | Medium (real corpus already has spaces) | jq `gsub("'";"''")` escaping; exact `IN` match; fixture test with `'` in filename |
| Scope references stale paths after re-sync | Medium | Graceful empty result; UI badge (Phase 3); optional path validation on scope POST |
| Very large selections blow env-var limits | Low (Linux `ARG_MAX` ≈ 2 MB; ~10k long paths) | Cap selection count in UI (e.g. 500) or fall back to unscoped above the cap |
| User confusion: scoped session answers "não encontrei" for out-of-scope questions | Medium | Pills always visible in header; prompt already tells the model the (scoped) file list, so it can say which docs it searched |
| Process-number heuristic vs. explicit scope conflict | Handled | Explicit scope disables the heuristic (Review Finding #7) |
| RAGSEC interaction | Low | Scope ANDs with clearance filter via the existing `condicoes` array; scope can only *narrow*, never widen, visibility |
| `updated_at` on `sessions` not bumped by scope change | Cosmetic | Acceptable; bump it in `set_session_scope` if session ordering should reflect scope edits |

**Open questions (decide during Phase 3):**
- Should scope changes mid-conversation append a system message ("Escopo alterado para:
  ...") so the transcript records what the model could see per turn? (`scope_changes`
  already stores the data; this is presentation only.)
- Folder-level persistence: today scope stores individual file paths. Selecting a folder
  checks all current children; new files added to that folder later are *not* auto-included.
  Acceptable for v1; folder-glob scopes (`docs/processos/%` via `LIKE`) are a possible v2.

---

## 8. Decision Log

| Decision | Alternatives considered | Rationale |
|----------|------------------------|-----------|
| **Scope is per-session, stored in `chat_history.db`** | Global scope in `settings` table; scope column on `sessions` | Matches NotebookLM's mental model — different investigations need different source sets concurrently. Separate table keeps `sessions` stable, allows `ON DELETE CASCADE`, and keeps the vector store (shared with CLI/RAGSEC) untouched. |
| **Filter at the SQLite level, not in jq** | Post-filter the jq similarity results | The full-corpus `SELECT` already serializes every chunk+768-D vector into jq; pre-filtering with the indexed `caminho_arquivo` column shrinks that payload, so scoped search is strictly cheaper. Post-filtering would also distort top-k (k slots wasted on out-of-scope chunks). |
| **Transport via `SCOPE_DOCS` env var (JSON array)** | argv `$2`; temp file; pipe-delimited string | Follows the existing precedent (`NON_INTERACTIVE`, `RAGSEC_CLEARANCE`). JSON survives any path characters; Python `json.dumps` → env → `jq` needs zero shell quoting. Draft's dual argv+env channel dropped as redundant. |
| **Exact `IN (...)` match on absolute paths** | `LIKE` patterns; basename match | Paths in the DB are the canonical identity (see `idx_caminho`); basenames can collide across folders; `LIKE` is wildcard-fragile with the spaces/dots present in real paths. |
| **Explicit scope disables the process-number heuristic** | AND both filters | AND silently yields zero results when the mentioned process is outside scope. A deliberate user selection must outrank a regex guess; the heuristic remains for unscoped sessions. |
| **Empty scope ⇒ all documents** | Empty scope ⇒ search nothing | Backward compatible (all existing sessions have no scope row) and fail-open for retrieval quality; "search nothing" is never what a user wants and is unreachable from the UI. |
| **New `POST /api/sessions` endpoint** | Attach scope only on first `/api/chat` | Lazy session creation (current `api_chat`) leaves no id to hang a scope on before the first message. Explicit creation is the clean fix; the inline `selected_docs` fallback covers race-y first messages. |
| **`scope_changes` audit table from day one** | Skip until needed | Cheap (one insert per scope edit), enables the mid-conversation transparency feature and dovetails with the RAGSEC audit-log philosophy (`ragsec_company_variant.md`). |

---

## 9. Critical Files

| File | Change |
|------|--------|
| `/home/lw_na/git/ai-ragjus/src/vector.sh` | Scope condition in `buscar_trechos_relevantes()` (`condicoes` block, ~line 152) |
| `/home/lw_na/git/ai-ragjus/src/rag_query.sh` | `SCOPE_DOCS` validation; scoped prompt metadata (~lines 64-66) |
| `/home/lw_na/git/ai-ragjus/web/db.py` | `session_doc_scope` + `scope_changes` schema; `get_session_scope` / `set_session_scope` |
| `/home/lw_na/git/ai-ragjus/web/app.py` | `import sqlite3`; `POST /api/sessions`; tree endpoint; scope GET/POST; `api_chat` env plumbing |
| `/home/lw_na/git/ai-ragjus/web/templates/chat.html` | Scope selector in sidebar; pills in header |
| `/home/lw_na/git/ai-ragjus/web/static/chat.js` | Tree rendering, scope state machine, pills |
| `/home/lw_na/git/ai-ragjus/web/static/style.css` | Scope selector / pills styles |

## Related Plans

- [`flask_gui_design.md`](flask_gui_design.md) — base web GUI architecture (subprocess
  bridge, SSE streaming, `chat_history.db`); this plan extends its Phase 1 model.
- [`flask_gui_backlog_implementation.md`](flask_gui_backlog_implementation.md) — sidebar
  UX work (rename/delete, lazy list) that shares the same sidebar real estate.
- [`flask_gui_context_window_monitor.md`](flask_gui_context_window_monitor.md) — scoping
  reduces retrieved-context noise, complementing context-pressure monitoring.
- [`ragsec_company_variant.md`](ragsec_company_variant.md) — clearance filter composes
  with scope via the shared `condicoes` mechanism; `scope_changes` mirrors its audit ethos.

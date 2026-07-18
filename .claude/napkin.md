# Napkin Runbook: AI-RAGJus

## Curation Rules
- Re-prioritize on every read.
- Keep recurring, high-value notes only.
- Max 10 items per category.
- Each item includes date + "Do instead".

## Execution & Validation (Highest Priority)

1. **[2026-07-12] Always verify Ollama is running before testing**
   Do instead: `curl -s http://localhost:11434 | jq .` — check response is non-empty before proceeding with RAG tests.

2. **[2026-07-12] Menu loop must never crash on Ollama timeout**
   Do instead: Wrap Ollama calls in subshells with `|| true` or capture errors; main jus.sh menu should always return to prompt even if inference fails.

3. **[2026-07-12] Config changes require restart**
   Do instead: Edit config.conf, then kill jus.sh and restart. Global variables are exported once at startup; they do not reload.

4. **[2026-07-12] Test extraction locally before trusting sync**
   Do instead: Run `pdftotext /path/to/test.pdf -` manually to verify pdftotext works; do not rely on sync alone to diagnose text extraction issues.

## Bash & Shell Reliability

1. **[2026-07-12] Always use jq -n --arg for JSON safety**
   Do instead: Never concatenate user input into JSON strings. Use `jq -n --arg model "$MODELO_IA" --arg prompt "$query"` to safely escape special chars.

2. **[2026-07-12] CHUNK_SIZE and CHUNK_OVERLAP tuning affects search quality**
   Do instead: For legal docs, test with CHUNK_SIZE=1000 (default); smaller chunks (500) fragment context, larger chunks (2000) lose precision. Resync after changes.

3. **[2026-07-12] Hash-based caching prevents duplicate ingestion**
   Do instead: sync idempotently hashes each file; changing a doc updates it, not processing unchanged files. If caching breaks, delete `.cache_vetorial/` and resync.

4. **[2026-07-12] SQLite .cache_vetorial/rag_store.db is single-threaded**
   Do instead: Safe for one user. Multi-user queries will lock DB. Check disk space before large reindex: `df -h .cache_vetorial/`.

## RAG & Vector Search

1. **[2026-07-12] Cosine similarity computed in jq, not SQL**
   Do instead: Vector search logic lives in src/vector.sh via jq; SQLite stores embeddings as JSON. If swapping embedding models, verify new embeddings are compatible dimension (768D for nomic-embed-text).

2. **[2026-07-12] Search result attribution requires jq parsing**
   Do instead: Results include `caminho_arquivo` (file path). Extract it with `jq -r '.[] | .caminho'` and display to user; do not modify the chunk structure.

3. **[2026-07-12] TEMPERATURA=0 ensures deterministic legal responses**
   Do instead: Hardcoded to 0 for reproducible advice. If user requests creativity, allow config override via advanced menu, not code change.

## Module & Architecture

1. **[2026-07-12] src/ingest.sh handles document extraction dispatch**
   Do instead: extrair_texto_limpo() matches file extension (pdf→pdftotext, docx→pandoc, txt→cat). To add new format: add case statement + tool binary.

2. **[2026-07-17] web/static/chat.js: guard async callbacks with sessionEpoch**
   Do instead: Any new async flow (fetch/SSE) that mutates session-scoped UI (context monitor, message list, currentSessionId) must capture `sessionEpoch` (bumped in loadSession/newChatBtn) or the session id at kickoff and bail if it changed by callback time. No AbortController pattern exists in this file.

3. **[2026-07-12] src/ai.sh implements self-healing model download**
   Do instead: If model not found, gerar_embedding() prompts user, auto-downloads via Ollama, retries. Do not skip this flow; it defines the UX.

## Local Development Setup

1. **[2026-07-12] Ollama must be running in background before starting jus.sh**
   Do instead: Terminal 1: `ollama serve`. Terminal 2: `./jus.sh`. Both must stay running concurrently.

2. **[2026-07-12] setup.sh auto-installs deps and downloads models**
   Do instead: Run `chmod +x setup.sh && ./setup.sh` once after cloning. Skips already-installed tools; only downloads missing models.

## Product Backlog (Prioritized + Planned)

2. ✅ **[2026-07-12] Build Flask web GUI (ChatGPT-like UI + chat history)**
   Do instead: See detailed plan in `.claude/plans/flask_gui_design.md`. Key: bridge src/*.sh modules as subprocesses (Phase 1), reuse existing `gerar_embedding`/`perguntar_ollama`/`buscar_trechos_relevantes`, add `NON_INTERACTIVE=1` env to suppress color/prompts, SSE streaming, separate `chat_history.db`, Phase 2 ports hot paths to Python.

3. ✅ **[2026-07-14] Flask GUI backlog: UI polish + memory features**
   Do instead: See `.claude/plans/flask_gui_design.md#backlog--future-work` and `.claude/plans/flask_gui_backlog_implementation.md`. Shipped: lazy-load chat list (pagination + infinite scroll), 3-dots menu (rename/delete chat, cascade), per-chat session memory (`session_memory` table + `web/memory.py` extraction), global cross-session memory with `/settings` inspector UI (`global_memory` table, manual+auto CRUD). `RAG_MEMORY_CONTEXT` env hook in `src/rag_query.sh` wires both into the prompt.

4. ✅ **[2026-07-14] Flask GUI backlog: context window monitor (qwen2.5:coder-7b pressure)**
   Do instead: See `.claude/plans/flask_gui_context_window_monitor.md`. Shipped: `CONTEXT_WINDOW` now wired as `num_ctx` in `ai.sh` (was silently ignored — Ollama defaulted to 4096); `web/context_tracker.py` estimates per-turn usage (`POST /api/sessions/<id>/context-usage`), reconciled with Ollama's exact `prompt_eval_count` via a new `{"type":"stats"}` SSE event once the turn completes. Color-coded badge in chat header (safe/caution/warning/critical).

5. **[2026-07-14] Enhance .md/.txt/.json document ingestion (metadata + structure)**
   Do instead: Currently `src/ingest.sh:31-33` uses raw `cat`. Improve: extract Markdown headings as context markers, strip YAML frontmatter into metadata, preserve code-block language tags, handle CSV as structured text (headers bold), flatten JSON objects into readable key:value text with nesting depth. Preserve semantic structure to improve RAG chunk relevance. See `src/ingest.sh` for extension point.

6. ✅ **[2026-07-14] Multi-doc scope selector (NotebookLM-style document focus)**
   Do instead: See `.claude/plans/multi_doc_scope_selector.md`. Key: `SCOPE_DOCS` env var (JSON array of absolute paths) → `caminho_arquivo IN (...)` condition in `src/vector.sh` (jq-escaped single quotes); per-session scope in `web/data/chat_history.db` (`session_doc_scope` table); new `POST /api/sessions` + scope endpoints; sidebar folder tree + header pills. Explicit scope disables the process-number heuristic; empty scope = all docs.

7. **[2026-07-12] Transform into Company Secret Data RAG (defense/tech products)**
   Do instead: See detailed plan in `.claude/plans/ragsec_company_variant.md`. Key: monorepo variant (RAGSEC_MODE flag), RBAC with 4 roles + clearance levels, doc classification (public/internal/confidential/secret), DLP rule engine with regex patterns, audit logging (append-only, hash-chained, 365-day retention), alter existing schema additively (no breaking changes).

8. ✅ **[2026-07-16] Auto-compact context when reaching 80% threshold**
   Do instead: Shipped: after each `/api/chat` turn, server checks usage against Ollama's exact `prompt_eval_count` (falls back to the char-based estimate) via `ContextTracker.from_config`; once it crosses the configured threshold, `memory.compact_session()` asks the model to consolidate the transcript + existing facts into one "📋 Resumo de contexto no turno N: ..." line, appends it to `session_memory`, then prunes older facts down to `COMPACT_KEEP_RECENT_FACTS` (=3) so the next turn's `RAG_MEMORY_CONTEXT` injects the summary instead of every accumulated fact. New `{"type":"compact"}` SSE event drives a toast + memory-panel refresh in `chat.js`. Enable/disable + threshold stored in `chat_history.db`'s generic `settings` table (`db.get_auto_compact_settings`/`set_auto_compact_settings`), editable live from `/settings` (no restart needed) via `POST /api/settings/auto-compact`.

9. ✅ **[2026-07-15] Attach files to instantly add new RAG context (session-scoped)**
   Do instead: Shipped: 📎 button + drag-drop overlay in chat UI → `POST /api/sessions/<id>/attach-file` → `src/attach_file.sh` (new bash bridge, mirrors `rag_query.sh`'s pattern) sources `extrair_texto_limpo`/`fatiar_texto`/`gerar_embedding` unchanged and streams `{"type":"chunk",...}` JSON lines; `web/ingest.py` persists them into `session_embeddings` (new table, `web/db.py`, `ON DELETE CASCADE` on `sessions` — auto-discarded on delete, never touches `.cache_vetorial/`). `src/vector.sh::buscar_trechos_sessao` + `SESSION_EMBED_DB`/`SESSION_ID` env vars let `rag_query.sh` merge session chunks *ahead of* global results each turn. Added `json`/`py` to `extrair_texto_limpo`'s plain-text case. Toast + progress bar in `chat.js`.

10. ✅ **[2026-07-16] Manual context compaction button ("Compact now")**
   Do instead: Shipped: 🗜️ button in chat header next to the context-window badge → `POST /api/sessions/<id>/compact` (synchronous, since the user is actively waiting) reuses the exact same `memory.compact_session()` as the item 8 auto-trigger, just with `reason="manual"`. Returns the checkpoint text for a toast confirmation; `chat.js` also refreshes the 🧠 memory disclosure panel (if open) and re-polls `/api/sessions/<id>/context-usage` so the badge reflects the shrunk context immediately.

11. **[2026-07-18] Display inference timing metrics: think time, answer time, throughput (tokens/s)**
   Do instead: Add SSE event `{"type":"stats","think_ms":..,"answer_ms":..,"tokens_per_sec":..}` after inference completes. Infer `think_ms` from Ollama's `eval_duration` (in nanoseconds) if exposed; fallback to elapsed time from prompt submission to first token. `answer_ms` = time from first token to stream close. Estimate `tokens_per_sec` using `prompt_eval_count + eval_count` divided by total wall-clock time (or use `output_tokens / answer_ms * 1000`). Render in chat header as a discrete metrics line (small grey text) or add toggleable "Metrics" panel in footer. UI: milliseconds for sub-second, seconds + decimals for longer runs.

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

2. **[2026-07-12] src/ai.sh implements self-healing model download**
   Do instead: If model not found, gerar_embedding() prompts user, auto-downloads via Ollama, retries. Do not skip this flow; it defines the UX.

## Local Development Setup

1. **[2026-07-12] Ollama must be running in background before starting jus.sh**
   Do instead: Terminal 1: `ollama serve`. Terminal 2: `./jus.sh`. Both must stay running concurrently.

2. **[2026-07-12] setup.sh auto-installs deps and downloads models**
   Do instead: Run `chmod +x setup.sh && ./setup.sh` once after cloning. Skips already-installed tools; only downloads missing models.

## Product Backlog (Prioritized + Planned)

1. **[2026-07-12] Add llama.cpp support (port 11434 compatibility)**
   Do instead: See detailed plan in `.claude/plans/llama_cpp_integration.md`. Key: protocol dialect abstraction (Ollama NDJSON vs OpenAI-compatible SSE), `BACKEND` case dispatcher, extract `_embed_ollama`/`_chat_ollama`/`_embed_llamacpp`/`_chat_llamacpp`, `NON_INTERACTIVE` guard. Backwards-compatible (default to Ollama).

2. **[2026-07-12] Build Flask web GUI (ChatGPT-like UI + chat history)**
   Do instead: See detailed plan in `.claude/plans/flask_gui_design.md`. Key: bridge src/*.sh modules as subprocesses (Phase 1), reuse existing `gerar_embedding`/`perguntar_ollama`/`buscar_trechos_relevantes`, add `NON_INTERACTIVE=1` env to suppress color/prompts, SSE streaming, separate `chat_history.db`, Phase 2 ports hot paths to Python.

3. **[2026-07-14] Flask GUI backlog: UI polish + memory features**
   Do instead: See `.claude/plans/flask_gui_design.md#backlog--future-work` and `.claude/plans/flask_gui_backlog_implementation.md`. Includes: lazy-load chat list, 3-dots menu (rename/delete chat), per-chat session memory, global cross-session memory with inspector UI.

4. **[2026-07-14] Flask GUI backlog: context window monitor (qwen2.5:coder-7b pressure)**
   Do instead: See `.claude/plans/flask_gui_context_window_monitor.md`. Estimate per-turn prompt size; wire `num_ctx` in `ai.sh`; emit `prompt_eval_count` stats. Display live % usage in chat header. Integrate with memory features to prevent truncation.

5. **[2026-07-14] Enhance .md/.txt/.json document ingestion (metadata + structure)**
   Do instead: Currently `src/ingest.sh:31-33` uses raw `cat`. Improve: extract Markdown headings as context markers, strip YAML frontmatter into metadata, preserve code-block language tags, handle CSV as structured text (headers bold), flatten JSON objects into readable key:value text with nesting depth. Preserve semantic structure to improve RAG chunk relevance. See `src/ingest.sh` for extension point.

6. **[2026-07-14] Multi-doc scope selector (NotebookLM-style document focus)**
   Do instead: Backend already scans subfolders recursively + stores full paths in DB. Add Flask UI: sidebar folder tree (expandable, checkboxes), select multiple docs to create a scoped chat session. Each session pins selected docs; RAG search only retrieves from those docs. Show selected docs as pills in chat header with breakdown. Enables user to focus analysis on a subset (e.g., contract + amendments) without full corpus noise.

7. **[2026-07-12] Transform into Company Secret Data RAG (defense/tech products)**
   Do instead: See detailed plan in `.claude/plans/ragsec_company_variant.md`. Key: monorepo variant (RAGSEC_MODE flag), RBAC with 4 roles + clearance levels, doc classification (public/internal/confidential/secret), DLP rule engine with regex patterns, audit logging (append-only, hash-chained, 365-day retention), alter existing schema additively (no breaking changes).

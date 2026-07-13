# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Summary

**AI-RAGJus** is a legal tech CLI for 100% offline document retrieval (RAG). Processes PDFs/DOCX/PPTX via pdftotext/pandoc, chunks text with jq, generates embeddings via local Ollama, stores in SQLite, and streams contextual responses. Bash-orchestrated with modular design. Zero external APIs, complete data privacy.

## Architecture: LIG Flow (Leitura, Indexação, Geração)

1. **Leitura**: pdftotext/pandoc extract text from documents in `PASTA_ALVO` folder
2. **Indexação**: jq chunks text (CHUNK_SIZE=1000, CHUNK_OVERLAP=200), Ollama generates embeddings via HTTP, SQLite stores `document_chunks` (path, text, embedding JSON)
3. **Geração**: User query → embedding → SQLite cosine similarity search → top-k chunks → RAG prompt → Ollama streams response

**Tech stack**: Bash v4.0+, jq, sqlite3, curl, pdftotext, pandoc. Ollama at localhost:11434. Models: nomic-embed-text (embeddings), qwen2.5:1.5b (inference, default).

## Code Organization

```
jus.sh              Main CLI (menu loop, chat interface, resilient to errors)
setup.sh            One-time provisioning
config.conf         Configuration (MODELO_IA, PASTA_ALVO, CHUNK_SIZE, TEMPERATURA=0)

src/
  config.sh         Load config, export globals
  ui.sh             Colors, typed-text effect, headers
  ingest.sh         extrair_texto_limpo(), fatiar_texto() (via jq), sincronizar_pasta()
  vector.sh         buscar_trechos_relevantes() (cosine similarity in jq)
  ai.sh             gerar_embedding(), perguntar_ollama() (Ollama API, auto-recovery)
```

## Key Design Patterns

- **Module sourcing**: jus.sh sources src/*.sh, exports config at startup (changes need restart)
- **Idempotent hashing**: Document MD5/SHA-256 prevents reprocessing
- **jq-based chunking & search**: Performance, no dependencies
- **Self-healing**: Missing model auto-downloads and retries
- **set -eo pipefail** with `|| true` guards main menu from errors
- **Streaming responses** with typing effect via curl streaming

## Running Locally

### Prerequisites
- **Ollama** installed and running as a background service: `ollama serve` (or via launchd/systemd)
- **System tools**: `pdftotext` (poppler-utils), `pandoc`, `jq`, `sqlite3`, `curl`
- **Hardware**: Min 4GB RAM (8GB+ recommended for smooth inference)

### Installation & Setup

```bash
# 1. Clone or enter repo
cd /path/to/ai-ragjus

# 2. Make scripts executable
chmod +x setup.sh jus.sh

# 3. Run setup (auto-installs deps, downloads models)
./setup.sh
# → Prompts for missing tools (pdftotext, pandoc, jq, sqlite3)
# → Downloads embedding model (nomic-embed-text, ~270MB)
# → Downloads inference model (qwen2.5:1.5b by default, ~1GB)
# → Creates config.conf and .cache_vetorial/ folder
```

### Start the Application

```bash
./jus.sh
```

**Main menu options:**
- **1**: Start RAG chat — ask questions about your documents
- **2**: Sync/reindex documents in `PASTA_ALVO` folder
- **3**: Change inference model (auto-downloads if missing)
- **4**: Change target documents folder path
- **5**: View hardware & system info
- **6**: Advanced configuration (chunking, temperature, etc.)
- **7**: Exit

### Minimal Workflow

```bash
# Terminal 1: Start Ollama (keeps running)
ollama serve

# Terminal 2: Run AI-RAGJus
cd /path/to/ai-ragjus
./jus.sh
→ Select option 2 (Sync documents)
→ Place .pdf/.docx files in the docs/ folder first
→ Wait for indexing to complete
→ Select option 1 (Chat)
→ Type a legal question
→ See response + source documents cited
```

### Configuration

Edit `config.conf` for:
- `PASTA_ALVO`: Path to documents folder (default: `./docs`)
- `MODELO_IA`: Inference model (default: `qwen2.5:1.5b`)
- `MODELO_EMBEDDING`: Embedding model (default: `nomic-embed-text`)
- `CHUNK_SIZE`: Text chunk size (default: 1000 chars)
- `CHUNK_OVERLAP`: Overlap between chunks (default: 200 chars)
- `TEMPERATURA`: Model temperature (default: 0 for deterministic legal responses)

**Restart jus.sh after changing config.conf.**

### Troubleshooting

| Issue | Check |
|-------|-------|
| "Cannot connect to Ollama" | `curl http://localhost:11434 \| jq .` — is Ollama running? |
| Slow sync | Check `.cache_vetorial/` disk usage: `du -sh .cache_vetorial/` |
| Sync fails on PDF | Test extraction: `pdftotext /path/to/test.pdf -` |
| Chat hangs | Ollama may be slow; no timeout set — consider `Ctrl+C` and retry |
| Wrong model loaded | Kill `jus.sh`, edit `config.conf`, restart |
| Search finds nothing | Check SQLite DB: `sqlite3 .cache_vetorial/rag_store.db "SELECT COUNT(*) FROM document_chunks;"` |

### Testing (if test directory exists)

```bash
# Unit tests
bats test/unit/

# Integration tests (end-to-end)
./test/integration/run_e2e_suite.sh
```

**Before running tests:**
- Ollama must be running
- Verify `pdftotext` works: `pdftotext --version`
- Small test PDFs in test/fixtures/ preferred

## Critical Constraints

- **TEMPERATURA=0** (deterministic legal advice); hardcoded in config.sh
- **No external APIs** — all local via Ollama
- **Single-threaded SQLite** — safe for one user only
- **Config reloads require restart** — globals set once at startup
- **768D embeddings** (nomic-embed-text) — swapping models may need schema change
- **Ollama timeout** — no curl timeout set; consider `--max-time 60` for slow responses

## Common Tasks

**Add document format**: Edit src/ingest.sh `extrair_texto_limpo()`, dispatch to tool by extension
**Adjust chunking**: Edit config.conf CHUNK_SIZE/CHUNK_OVERLAP, restart, resync
**Swap models**: Edit config.conf MODELO_IA/MODELO_EMBEDDING; app auto-downloads if missing, restart & resync
**Debug sync**: `curl http://localhost:11434 | jq .` (Ollama running?), `pdftotext file.pdf -` (manual extract), check `.cache_vetorial/` disk usage

## Code Style

- Functions: `lowercase_with_underscores` (e.g., `gerar_embedding`)
- Globals: ALL_CAPS (MODELO_IA, CACHE_DIR)
- Colors: `$GREEN`, `$BLUE`, `$RED`, `$NC` from ui.sh
- JSON: Always `jq -n --arg` or `--argjson`, never string concat
- Errors: `[ERRO]`, `[AVISO]`, `[OK]` colored, `>&2` to stderr
- Comments: Minimal; only explain WHY for non-obvious logic

## Before You Start

✓ Verify Ollama: `curl http://localhost:11434 | jq .`
✓ Test extraction: `pdftotext /path/to/test.pdf -`
✓ Use small test docs (1-2 pages); large PDFs slow to embed
✓ Check DB after sync: `sqlite3 .cache_vetorial/rag_store.db "SELECT COUNT(*) FROM document_chunks;"`

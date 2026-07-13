# llama.cpp Backend Integration Plan

## Overview

Add [llama.cpp server](https://github.com/ggml-org/llama.cpp) as an alternative
inference backend alongside Ollama. Both listen on `localhost:11434`, so the
selector is a **protocol dialect switch**, not a URL switch. Ollama speaks its
native `/api/generate` + `/api/embeddings` (NDJSON stream, `.response` token
field); llama.cpp's `llama-server` exposes an **OpenAI-compatible** surface at
`/v1/chat/completions` + `/v1/embeddings` (SSE stream, `choices[].delta.content`).

Goal: introduce a `BACKEND` config var (`ollama` | `llamacpp`, default `ollama`)
that routes the two I/O functions in `src/ai.sh` to the correct dialect, with
zero behavior change for existing Ollama users.

## Architecture

Keep the current thin design. The only two functions that touch the network are
`gerar_embedding()` and `perguntar_ollama()` in `src/ai.sh:14` and `:66`. Wrap
each in a dispatcher and add backend-specific implementations:

```
gerar_embedding(texto)  -> case $BACKEND in ollama) _embed_ollama;; llamacpp) _embed_llamacpp;; esac
perguntar_ia(prompt)    -> case $BACKEND in ollama) _chat_ollama;;  llamacpp) _chat_llamacpp;;  esac
```

Rename `perguntar_ollama` to a backend-neutral `perguntar_ia` and keep
`perguntar_ollama` as a one-line alias calling `perguntar_ia` (protects existing
callers). All auto-healing / model-pull logic (`/api/pull`) stays **inside**
`_chat_ollama` / `_embed_ollama` only — llama.cpp loads its model at server
launch, so there is no pull equivalent (see Constraints).

## Implementation Steps

### 1. `src/config.sh`
- Add default `BACKEND="ollama"` near `OLLAMA_URL` (`config.sh:14`).
- Add `BACKEND) BACKEND="$value" ;;` to both the loader whitelist (`:33` case)
  and the `atualizar_configuracao` case (`:63`).
- Add `BACKEND` to the `export` line (`:48`).

### 2. `config.conf` / `config.conf.example`
- Document and add `BACKEND="ollama"  # ollama | llamacpp`.

### 3. `src/ai.sh` — refactor (core work)
- Extract current body of `gerar_embedding` into `_embed_ollama`; current body of
  `perguntar_ollama` into `_chat_ollama`, byte-for-byte identical so the Ollama
  path is provably unchanged.
- Add `_embed_llamacpp`:
  ```bash
  json=$(jq -n --arg m "$MODELO_EMBEDDING" --arg t "$texto" '{model:$m, input:$t}')
  resp=$(curl -s "$OLLAMA_URL/v1/embeddings" -H 'Content-Type: application/json' -d "$json")
  echo "$resp" | jq -c '.data[0].embedding'
  ```
- Add `_chat_llamacpp` (streaming SSE):
  ```bash
  json=$(jq -n --arg m "$MODELO_IA" --arg p "$prompt" --argjson temp "$TEMPERATURA" \
    '{model:$m, messages:[{role:"user",content:$p}], stream:true, temperature:$temp}')
  curl -s -N "$OLLAMA_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$json" \
  | while IFS= read -r line; do
      line="${line#data: }"; [ "$line" = "[DONE]" ] && break
      tok=$(echo "$line" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
      [ -n "$tok" ] && echo -ne "${GREEN}${tok}${NC}"
    done
  ```
  Note the `data: ` prefix strip and `[DONE]` sentinel — the two differences from
  Ollama's raw NDJSON. `--argjson temp` preserves the existing `TEMPERATURA` wiring.
- Add dispatchers `gerar_embedding` / `perguntar_ia` with the `case "$BACKEND"`
  routing above; keep `perguntar_ollama` alias.

### 4. `jus.sh` — menu
- In `menu_configuracoes_avancadas` (`jus.sh:190`), add option "Alterar Backend de
  Inferência [Atual: $BACKEND]" that prompts `ollama`/`llamacpp` and calls
  `atualizar_configuracao "BACKEND" "$novo" "$APP_DIR"`. Renumber the "Voltar" item
  and the `read -p` range prompt (`:206`).
- Call site `perguntar_ollama "$prompt"` (`jus.sh:122`) keeps working via alias;
  optionally switch to `perguntar_ia`.

### 5. Endpoint detection & fallback
Add `detectar_backend()` in `ai.sh`, invoked at startup when `BACKEND` is unset or
`auto`:
- `GET $OLLAMA_URL/api/tags` -> 200 with `.models` => Ollama.
- Else `GET $OLLAMA_URL/v1/models` -> 200 => llama.cpp.
- Else warn: no server reachable on 11434.
Explicit `BACKEND` in config always wins over auto-detection.

## Testing

- **Unit (dialect parsing):** feed captured fixtures (one Ollama NDJSON chunk, one
  llama.cpp SSE `data:` line) into the token/embedding `jq` filters; assert the
  extracted values match. Store fixtures under `test/fixtures/`.
- **Integration:** run real `llama-server -m model.gguf --port 11434 --embeddings`;
  execute one embedding + one chat query; assert non-empty streamed output and a
  numeric-array embedding.
- **Regression:** with `BACKEND=ollama`, confirm `_chat_ollama`/`_embed_ollama`
  bytes unchanged (`git diff` on the extracted blocks) and existing chat + ingest
  flows still work end to end.
- **Detection:** point `detectar_backend` at each server; assert correct result and
  the unreachable warning when nothing listens.

## Known Constraints

- **No auto-pull for llama.cpp:** model is fixed at server launch; `MODELO_IA` is
  advisory. "Model not found" surfaces as an HTTP error, not a pullable state —
  print a clear "start llama-server with the desired GGUF" message instead of the
  Ollama `/api/pull` prompt.
- **`--embeddings` flag required** for llama.cpp embeddings; a chat-only server
  returns 501 on `/v1/embeddings`. Detect and warn.
- **Single model per llama-server process** (vs. Ollama's on-demand loading);
  running distinct chat and embedding models needs two ports — out of scope for
  v1, note as future work.
- **jq dependency** already assumed project-wide; no new deps introduced.
- **Backwards compatibility:** default `BACKEND=ollama` + untouched `_*_ollama`
  bodies + `perguntar_ollama` alias guarantee existing installs behave identically
  with no config migration.

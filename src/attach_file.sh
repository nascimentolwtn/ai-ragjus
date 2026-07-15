#!/bin/bash
# =========================================================================
# AI-RAGJus - Ponte não-interativa para anexos de sessão (Web GUI, item 9)
# =========================================================================
# Extrai texto, faz chunking e gera embeddings para UM arquivo anexado por um
# usuário a uma conversa da interface Web, reaproveitando as MESMAS funções
# usadas pelo CLI (src/ingest.sh::extrair_texto_limpo / fatiar_texto,
# src/ai.sh::gerar_embedding). Não toca no acervo global
# (.cache_vetorial/rag_store.db) nem em src/vector.sh - o chamador (web/ingest.py)
# é responsável por persistir os chunks emitidos aqui na tabela GUI-owned
# session_embeddings (web/data/chat_history.db), escopada por sessão.
#
# Uso: NON_INTERACTIVE=1 bash src/attach_file.sh <caminho_arquivo>
#
# Eventos emitidos em stdout (um objeto JSON por linha):
#   {"type":"chunk","index":i,"text":"...","embedding":[...]}
#   {"type":"error","content":"..."}
#   {"type":"done","total_chunks":N}
set -eo pipefail

export NON_INTERACTIVE=1

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

modulos=("config.sh" "ai.sh" "ingest.sh")
for modulo in "${modulos[@]}"; do
    if [ -f "$APP_DIR/src/$modulo" ]; then
        source "$APP_DIR/src/$modulo"
    else
        jq -cn --arg msg "Módulo não encontrado em src/$modulo" '{type:"error", content:$msg}'
        echo '{"type":"done","total_chunks":0}'
        exit 1
    fi
done

carregar_configuracoes "$APP_DIR"

arquivo="$1"

if [ -z "$arquivo" ] || [ ! -f "$arquivo" ]; then
    jq -cn '{type:"error", content:"Arquivo não encontrado."}'
    echo '{"type":"done","total_chunks":0}'
    exit 1
fi

# 1. Extrai texto (mesma função usada por sincronizar_documentos)
texto=$(extrair_texto_limpo "$arquivo" || echo "")

if [ -z "$texto" ]; then
    jq -cn '{type:"error", content:"Falha ao extrair texto ou arquivo vazio."}'
    echo '{"type":"done","total_chunks":0}'
    exit 1
fi

# 2. Fatiamento em chunks (idêntico ao acervo global)
chunks_json=$(fatiar_texto "$texto")
num_chunks=$(echo "$chunks_json" | jq '. | length')

# 3. Gera embeddings chunk a chunk e emite cada um como evento JSON
for (( i=0; i<num_chunks; i++ )); do
    chunk_texto=$(echo "$chunks_json" | jq -r --argjson idx "$i" '.[$idx]')

    vetor=$(gerar_embedding "$chunk_texto" 2>/dev/null || echo "")

    if [ -n "$vetor" ]; then
        jq -cn --argjson idx "$i" --arg text "$chunk_texto" --argjson emb "$vetor" \
            '{type:"chunk", index:$idx, text:$text, embedding:$emb}'
    else
        jq -cn --argjson idx "$i" \
            '{type:"error", content: ("Falha ao gerar embedding para o bloco " + ($idx|tostring) + ".")}'
    fi
done

echo "{\"type\":\"done\",\"total_chunks\":$num_chunks}"

#!/bin/bash
# =========================================================================
# AI-RAGJus - Módulo de Integração com Ollama (Embeddings & Chat)
# =========================================================================

# Gera o vetor de embedding para um bloco de texto
# Retorna uma string no formato de array JSON: [0.123, -0.456, ...]
gerar_embedding() {
    local texto="$1"
    
    # Valida parâmetros globais carregados
    if [ -z "$OLLAMA_URL" ] || [ -z "$MODELO_EMBEDDING" ]; then
        echo "Erro: OLLAMA_URL ou MODELO_EMBEDDING não estão definidos." >&2
        return 1
    fi

    # Codifica o texto de forma segura para JSON usando jq
    local json_payload
    json_payload=$(jq -n --arg model "$MODELO_EMBEDDING" --arg prompt "$texto" '{"model": $model, "prompt": $prompt}')

    # Faz a requisição à API de embeddings do Ollama
    local response
    response=$(curl -s -X POST "$OLLAMA_URL/api/embeddings" \
        -H "Content-Type: application/json" \
        -d "$json_payload" 2>/dev/null || echo "")

    if [ -z "$response" ] || echo "$response" | grep -q "error"; then
        local err_msg
        err_msg=$(echo "$response" | jq -r '.error' 2>/dev/null || echo "Falha de comunicação com o Ollama")
        echo "Erro ao gerar embedding: $err_msg" >&2
        return 1
    fi

    # Extrai o array de embeddings
    echo "$response" | jq -c '.embedding'
}

# Envia o prompt montado (pergunta + contexto) para a API do Ollama e exibe em tempo real (streaming)
perguntar_ollama() {
    local prompt="$1"

    if [ -z "$OLLAMA_URL" ] || [ -z "$MODELO_IA" ]; then
        echo "Erro: OLLAMA_URL ou MODELO_IA não estão definidos." >&2
        return 1
    fi

    local json_payload
    json_payload=$(jq -n --arg model "$MODELO_IA" --arg prompt "$prompt" --bool stream true '{"model": $model, "prompt": $prompt, "stream": $stream}')

    # Executa a chamada em streaming
    # Cada bloco de resposta é impresso no terminal imediatamente à medida que chega
    curl -s -N -X POST "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$json_payload" | while IFS= read -r line; do
            if [ -n "$line" ]; then
                # Decodifica a resposta parcial e imprime sem quebra de linha
                local token
                token=$(echo "$line" | jq -r '.response' 2>/dev/null || echo -n "")
                echo -ne "${GREEN}${token}${NC}"
            fi
        done
    echo "" # Quebra de linha ao final do streaming
}

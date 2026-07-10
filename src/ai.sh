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
    json_payload=$(jq -n --arg model "$MODELO_IA" --arg prompt "$prompt" '{"model": $model, "prompt": $prompt, "stream": true}')

    local response_started=false
    local has_error=false
    local tmp_err
    tmp_err=$(mktemp 2>/dev/null || echo "/tmp/ollama_err.txt")

    # Executa a chamada em streaming e processa linha a linha (suporta EOF sem newline)
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$line" ]; then
            # Verifica se há mensagem de erro no JSON retornado
            local erro
            erro=$(echo "$line" | jq -r '.error // empty' 2>/dev/null || echo "")
            if [ -n "$erro" ]; then
                echo -e "\n${RED}[Erro do Ollama]: $erro${NC}" >&2
                has_error=true
                break
            fi

            local token
            token=$(echo "$line" | jq -r '.response // empty' 2>/dev/null || echo -n "")
            if [ -n "$token" ]; then
                echo -ne "${GREEN}${token}${NC}"
                response_started=true
            fi
        fi
    done < <(curl -s -N -X POST "$OLLAMA_URL/api/generate" \
        -H "Content-Type: application/json" \
        -d "$json_payload" 2>"$tmp_err" || echo "")

    # Se nada foi impresso, diagnostica a falha
    if [ "$response_started" = false ] && [ "$has_error" = false ]; then
        if [ -f "$tmp_err" ] && [ -s "$tmp_err" ]; then
            local curl_err
            curl_err=$(cat "$tmp_err")
            echo -e "${RED}[Erro de Conexão]: Falha ao se conectar com o Ollama.${NC}" >&2
            echo -e "${RED}Detalhes: $curl_err${NC}" >&2
        else
            echo -e "${RED}[Erro]: Nenhuma resposta foi retornada pelo Ollama.${NC}" >&2
            echo -e "${RED}Verifique se o modelo '$MODELO_IA' está carregado corretamente e se há memória RAM livre suficiente.${NC}" >&2
        fi
    fi

    rm -f "$tmp_err" 2>/dev/null || true
    echo "" # Quebra de linha ao final
}

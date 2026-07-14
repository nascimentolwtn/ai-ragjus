#!/bin/bash
# =========================================================================
# AI-RAGJus - Módulo de Integração com Ollama (Embeddings & Chat com Auto-recuperação)
# =========================================================================

# Cores ANSI para feedback visual do auto-healing
# Em modo NON_INTERACTIVE (interface Web) as cores são suprimidas para que
# apenas JSON limpo chegue ao consumidor (ver perguntar_ollama/gerar_embedding).
if [ "$NON_INTERACTIVE" = "1" ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

# Gera o vetor de embedding para um bloco de texto (com auto-recuperação de modelo ausente)
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

    # Trata respostas de erro do Ollama
    if [ -z "$response" ] || echo "$response" | grep -q "error"; then
        local err_msg
        err_msg=$(echo "$response" | jq -r '.error // empty' 2>/dev/null || echo "")
        
        # Se for erro de modelo ausente (not found)
        if echo "$err_msg" | grep -iq "not found"; then
            if [ "$NON_INTERACTIVE" = "1" ]; then
                jq -cn --arg msg "Modelo de embedding '$MODELO_EMBEDDING' não encontrado no Ollama." '{type:"error", content:$msg}' >&2
                return 1
            fi

            echo -e "\n${YELLOW}[AVISO] O modelo de indexação '$MODELO_EMBEDDING' não foi encontrado no seu Ollama.${NC}" >&2
            local baixar_embed
            read -p "Deseja realizar o download dele automaticamente agora? (~270MB) (s/n): " baixar_embed < /dev/tty

            if [ "$baixar_embed" = "s" ] || [ "$baixar_embed" = "S" ]; then
                echo -e "${BLUE}Baixando nomic-embed-text...${NC}" >&2
                curl -d "{\"name\": \"$MODELO_EMBEDDING\"}" "$OLLAMA_URL/api/pull" >&2
                echo -e "\n${GREEN}[OK] Modelo de embedding instalado! Reexecutando indexação...${NC}" >&2

                # Chamada recursiva após o download
                gerar_embedding "$texto"
                return $?
            fi
        fi

        # Se falhar e não puder recuperar
        [ -z "$err_msg" ] && err_msg="Falha de comunicação com o Ollama"
        if [ "$NON_INTERACTIVE" = "1" ]; then
            jq -cn --arg msg "Erro ao gerar embedding: $err_msg" '{type:"error", content:$msg}' >&2
        else
            echo "Erro ao gerar embedding: $err_msg" >&2
        fi
        return 1
    fi

    # Extrai o array de embeddings
    echo "$response" | jq -c '.embedding'
}

# Envia o prompt montado para o Ollama em tempo real (com loop de retry / auto-recuperação)
perguntar_ollama() {
    local prompt="$1"

    if [ -z "$OLLAMA_URL" ] || [ -z "$MODELO_IA" ]; then
        echo "Erro: OLLAMA_URL ou MODELO_IA não estão definidos." >&2
        return 1
    fi

    # CONTEXT_WINDOW vira num_ctx no payload: sem isso o Ollama ignora a
    # config e usa o padrão de 4096, truncando o prompt silenciosamente
    # (ver .claude/plans/flask_gui_context_window_monitor.md).
    local ctx_window="${CONTEXT_WINDOW:-16384}"

    local json_payload
    json_payload=$(jq -n --arg model "$MODELO_IA" --arg prompt "$prompt" --argjson temp "$TEMPERATURA" --argjson ctx "$ctx_window" '{"model": $model, "prompt": $prompt, "stream": true, "options": {"temperature": $temp, "num_ctx": $ctx}}')

    while true; do
        local response_started=false
        local has_error=false
        local should_retry=false
        local tmp_err
        tmp_err=$(mktemp 2>/dev/null || echo "/tmp/ollama_err.txt")

        # Executa a chamada em streaming e processa linha a linha (suporta EOF sem newline)
        while IFS= read -r line || [ -n "$line" ]; do
            if [ -n "$line" ]; then
                # Verifica se há mensagem de erro no JSON retornado
                local erro
                erro=$(echo "$line" | jq -r '.error // empty' 2>/dev/null || echo "")
                if [ -n "$erro" ]; then
                    # Se o modelo não foi encontrado (not found)
                    if echo "$erro" | grep -iq "not found"; then
                        if [ "$NON_INTERACTIVE" = "1" ]; then
                            jq -cn --arg msg "Modelo '$MODELO_IA' não encontrado no Ollama." '{type:"error", content:$msg}'
                            has_error=true
                            break
                        fi

                        echo -e "\n${YELLOW}[AVISO] O modelo lógico '$MODELO_IA' não foi encontrado no seu Ollama.${NC}" >&2
                        local baixar_ia
                        read -p "Deseja realizar o download dele automaticamente agora? (s/n): " baixar_ia < /dev/tty
                        if [ "$baixar_ia" = "s" ] || [ "$baixar_ia" = "S" ]; then
                            echo -e "${BLUE}Baixando o modelo '$MODELO_IA'... Isso pode levar alguns minutos.${NC}" >&2
                            curl -d "{\"name\": \"$MODELO_IA\"}" "$OLLAMA_URL/api/pull" >&2
                            echo -e "\n${GREEN}[OK] Modelo instalado! Reprocessando sua pergunta...${NC}\n" >&2
                            should_retry=true
                            break
                        fi
                    fi

                    # Outros erros comuns
                    if [ "$NON_INTERACTIVE" = "1" ]; then
                        jq -cn --arg msg "$erro" '{type:"error", content:$msg}'
                    else
                        echo -e "\n${RED}[Erro do Ollama]: $erro${NC}" >&2
                    fi
                    has_error=true
                    break
                fi

                local token
                token=$(echo "$line" | jq -r '.response // empty' 2>/dev/null || echo -n "")
                if [ -n "$token" ]; then
                    if [ "$NON_INTERACTIVE" = "1" ]; then
                        jq -cn --arg t "$token" '{type:"token", content:$t}'
                    else
                        echo -ne "${GREEN}${token}${NC}"
                    fi
                    response_started=true
                fi

                # Última linha do streaming (done:true) traz as contagens
                # exatas de tokens usadas pelo Ollama - emite como evento
                # "stats" para o monitor de janela de contexto da interface
                # web substituir a estimativa por caracteres pelo valor real.
                local is_done
                is_done=$(echo "$line" | jq -r '.done // false' 2>/dev/null || echo "false")
                if [ "$is_done" = "true" ] && [ "$NON_INTERACTIVE" = "1" ]; then
                    echo "$line" | jq -c '{type:"stats", prompt_eval_count: (.prompt_eval_count // null), eval_count: (.eval_count // null)}' 2>/dev/null || true
                fi
            fi
        done < <(curl -s -N -X POST "$OLLAMA_URL/api/generate" \
            -H "Content-Type: application/json" \
            -d "$json_payload" 2>"$tmp_err" || echo "")

        rm -f "$tmp_err" 2>/dev/null || true

        # Se agendou retry, roda o loop principal novamente
        if [ "$should_retry" = true ]; then
            continue
        fi

        # Se nada foi impresso, diagnostica a falha
        if [ "$response_started" = false ] && [ "$has_error" = false ]; then
            if [ "$NON_INTERACTIVE" = "1" ]; then
                jq -cn --arg msg "Nenhuma resposta foi retornada pelo Ollama. Verifique se o modelo '$MODELO_IA' está carregado corretamente e se há memória RAM livre suficiente." '{type:"error", content:$msg}'
            else
                echo -e "${RED}[Erro]: Nenhuma resposta foi retornada pelo Ollama.${NC}" >&2
                echo -e "${RED}Verifique se o modelo '$MODELO_IA' está carregado corretamente e se há memória RAM livre suficiente.${NC}" >&2
            fi
        fi

        break
    done

    # Quebra de linha ao final do streaming (apenas na CLI interativa; o modo
    # NON_INTERACTIVE já emite eventos JSON linha-a-linha e não precisa disso)
    [ "$NON_INTERACTIVE" = "1" ] || echo ""
}

#!/bin/bash
# =========================================================================
# AI-RAGJus - Gerenciador de Modelos do Ollama
# =========================================================================
set -eo pipefail

GREEN='\033[0;32m'
GREEN_BOLD='\033[1;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem Cor

OLLAMA_HOST="http://localhost:11434"

limpar_tela() {
    if command -v tput &> /dev/null; then tput clear; else echo -ne "\033[H\033[2J"; fi
}

verificar_ollama() {
    if ! curl -s --connect-timeout 2 "$OLLAMA_HOST" &> /dev/null; then
        echo -e "${RED}[ERRO] Não foi possível conectar ao Ollama em $OLLAMA_HOST.${NC}"
        echo -e "Certifique-se de que o Ollama está rodando localmente."
        exit 1
    fi
}

listar_e_excluir_modelos() {
    while true; do
        limpar_tela
        verificar_ollama

        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo -e "${GREEN_BOLD}             AI-RAGJUS - GERENCIADOR DE MODELOS LOCAL (OLLAMA)           ${NC}"
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo -e " Abaixo estão listados os modelos instalados em seu computador."
        echo -e " Você pode escolher um modelo para desinstalar e liberar espaço em disco."
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo ""

        # Obtém a lista de modelos via API
        local response
        response=$(curl -s "$OLLAMA_HOST/api/tags" 2>/dev/null || echo "")

        if [ -z "$response" ] || [ "$response" = "{}" ]; then
            echo -e "  ${YELLOW}(Nenhum modelo encontrado no Ollama local)${NC}"
            echo ""
            read -p "Pressione [Enter] para voltar..."
            return
        fi

        # Popula o array de modelos de forma compatível
        local models=()
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                models+=("$line")
            fi
        done < <(echo "$response" | jq -r '.models[].name' 2>/dev/null || true)

        if [ ${#models[@]} -eq 0 ]; then
            echo -e "  ${YELLOW}(Nenhum modelo encontrado no Ollama local)${NC}"
            echo ""
            read -p "Pressione [Enter] para sair..."
            break
        fi

        # Exibe os modelos com índices
        for i in "${!models[@]}"; do
            # Formata tamanho para exibição amigável
            local size_bytes
            size_bytes=$(echo "$response" | jq -r --argjson idx "$i" '.models[$idx].size' 2>/dev/null || echo "0")
            local size_gb
            size_gb=$(echo "scale=2; $size_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
            
            echo -e "  ${GREEN_BOLD}$((i+1)))${NC} ${BLUE}${models[i]}${NC} (${size_gb} GB)"
        done
        echo ""
        echo -e "  ${GREEN_BOLD}s)${NC} Voltar/Sair"
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo ""

        local escolha
        read -p "Selecione o número do modelo que deseja excluir: " escolha

        if [ "$escolha" = "s" ] || [ "$escolha" = "S" ]; then
            break
        fi

        # Valida se a escolha é um número e está dentro da faixa
        if [[ "$escolha" =~ ^[0-9]+$ ]] && [ "$escolha" -ge 1 ] && [ "$escolha" -le "${#models[@]}" ]; then
            local idx=$((escolha-1))
            local model_name="${models[idx]}"

            echo -e "\n${RED}[ATENÇÃO] Você está prestes a excluir permanentemente o modelo: $model_name${NC}"
            read -p "Você tem certeza absoluta que deseja desinstalar este modelo? (s/n): " confirmar
            
            if [ "$confirmar" = "s" ] || [ "$confirmar" = "S" ]; then
                echo -e "${BLUE}Excluindo modelo '$model_name' do computador...${NC}"
                
                # Executa a chamada de delete via API
                local status_code
                status_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$OLLAMA_HOST/api/delete" \
                    -H "Content-Type: application/json" \
                    -d "{\"name\": \"$model_name\"}")

                if [ "$status_code" = "200" ]; then
                    echo -e "${GREEN}[OK] Modelo '$model_name' desinstalado com sucesso!${NC}"
                else
                    echo -e "${RED}[ERRO] Falha ao desinstalar o modelo (HTTP status: $status_code)${NC}" >&2
                fi
                sleep 2
            else
                echo -e "${YELLOW}Exclusão cancelada pelo usuário.${NC}"
                sleep 1
            fi
        else
            echo -e "${RED}Opção inválida. Tente novamente.${NC}" >&2
            sleep 1
        fi
    done
}

# Inicializa o script
listar_e_excluir_modelos

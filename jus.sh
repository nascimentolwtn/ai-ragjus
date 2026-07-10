#!/bin/bash
# =========================================================================
# AI-RAGJus Master CLI Script
# =========================================================================
# Configura o tratamento rigoroso de erros por padrão.
# Para evitar que o loop principal seja interrompido por erros, comandos individuais
# serão executados em subshells ou capturados com || true.
set -eo pipefail

# 1. Obter o diretório absoluto do script para importações resilientes
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 2. Importação de Módulos
modulos=("config.sh" "ui.sh" "ai.sh" "ingest.sh" "vector.sh")
for modulo in "${modulos[@]}"; do
    if [ -f "$APP_DIR/src/$modulo" ]; then
        source "$APP_DIR/src/$modulo"
    else
        echo "Erro: Módulo não encontrado em src/$modulo" >&2
        exit 1
    fi
done

# Carrega as configurações
carregar_configuracoes "$APP_DIR"

# 3. Função do Menu Principal
menu_principal() {
    while true; do
        limpar_tela_retro
        exibir_cabecalho
        
        echo -e "  ${GREEN}1)${NC} Iniciar Busca Jurídica RAG (Chat)"
        echo -e "  ${GREEN}2)${NC} Sincronizar / Reindexar Pasta de Documentos [Atual: ${BLUE}$PASTA_ALVO${NC}]"
        echo -e "  ${GREEN}3)${NC} Alterar Modelo da IA Local [Atual: ${BLUE}$MODELO_IA${NC}]"
        echo -e "  ${GREEN}4)${NC} Alterar Pasta de Documentos Alvo"
        echo -e "  ${GREEN}5)${NC} Informações de Hardware & Sistema"
        echo -e "  ${GREEN}6)${NC} Sair do Sistema"
        echo -e ""
        echo -e "${GREEN}=========================================================================${NC}"
        
        local opcao
        read -p "Digite a opção desejada (1-6): " opcao
        
        case "$opcao" in
            1)
                limpar_tela_retro
                exibir_cabecalho
                exibir_texto_digitando "Chat Jurídico RAG Iniciado. Digite 'sair' para retornar ao menu."
                echo -e "-------------------------------------------------------------------------"
                
                while true; do
                    echo -ne "\n${GREEN_BOLD}Advogado (Pergunta): ${NC}"
                    local query
                    read -r query
                    
                    if [ "$query" = "sair" ] || [ "$query" = "SAIR" ]; then
                        break
                    fi
                    
                    if [ -z "$query" ]; then
                        continue
                    fi
                    
                    echo -ne "${GREEN_DIM}Buscando fatos e gerando resposta...${NC}\n"
                    
                    # 1. Gera embedding para a pergunta
                    local vetor_query
                    vetor_query=$(gerar_embedding "$query" 2>/dev/null || echo "")
                    
                    if [ -z "$vetor_query" ]; then
                        echo -e "${RED}[Erro] Falha ao processar embedding da pergunta. O Ollama está rodando?${NC}" >&2
                        continue
                    fi
                    
                    # 2. Busca trechos semelhantes
                    local trechos
                    trechos=$(buscar_trechos_relevantes "$vetor_query" 2>/dev/null || echo "[]")
                    
                    # Exibe fontes localizadas para transparência de RAG
                    local fontes
                    fontes=$(echo "$trechos" | jq -r '.[] | .caminho' 2>/dev/null | awk -F/ '{print $NF}' | sort -u | paste -sd ", " - || echo "")
                    if [ -n "$fontes" ]; then
                        echo -e "${BLUE}[Fontes lidas: $fontes]${NC}"
                    fi
                    
                    # 3. Formata contexto
                    local contexto
                    contexto=$(echo "$trechos" | jq -r '.[] | "Arquivo: " + .caminho + "\nTrecho: " + .texto + "\n---"' 2>/dev/null || echo "")
                    
                    # 4. Monta o prompt RAG
                    local prompt
                    if [ -n "$contexto" ]; then
                        prompt="Você é um assistente jurídico especialista de elite. Baseado estritamente nos trechos de documentos fornecidos abaixo, responda de forma muito clara, técnica e objetiva à pergunta do usuário. Forneça sempre o nome do arquivo fonte de onde retirou as informações. Se as informações não estiverem no contexto fornecido, diga que não localizou essa informação no acervo de documentos locais.

Documentos Jurídicos de Contexto:
$contexto

Pergunta do Usuário:
$query"
                    else
                        prompt="Você é um assistente jurídico de elite. Diga de forma amigável e profissional que seu acervo local de documentos jurídicos está vazio ou não possui informações correlacionadas à pergunta, e oriente o usuário a colocar documentos na pasta de destino correspondente e reindexar.
                        
Pergunta do Usuário:
$query"
                    fi

                    echo -e "\n${GREEN_BOLD}AI-JusRAG (Resposta):${NC}"
                    perguntar_ollama "$prompt"
                    echo -e "\n-------------------------------------------------------------------------"
                done
                ;;
            2)
                limpar_tela_retro
                exibir_cabecalho
                exibir_texto_digitando "Iniciando sincronização de documentos..."
                sincronizar_documentos
                echo ""
                read -p "Pressione [Enter] para retornar ao menu..."
                ;;
            3)
                limpar_tela_retro
                echo -e "${GREEN}Alterar Modelo de IA${NC}"
                echo -e "Modelos comuns: qwen2.5:7b, qwen2.5:1.5b, llama3:8b, phi3"
                local novo_modelo
                read -p "Digite o novo modelo (ou pressione Enter para manter '$MODELO_IA'): " novo_modelo
                if [ -n "$novo_modelo" ]; then
                    atualizar_configuracao "MODELO_IA" "$novo_modelo" "$APP_DIR"
                    exibir_texto_digitando "Configuração atualizada: MODELO_IA=$novo_modelo"
                fi
                read -p "Pressione [Enter] para retornar ao menu..."
                ;;
            4)
                limpar_tela_retro
                echo -e "${GREEN}Alterar Diretório de Documentos Alvo${NC}"
                local novo_caminho
                read -p "Digite o caminho completo da pasta (ex: /Users/advogado/Documentos): " novo_caminho
                if [ -d "$novo_caminho" ]; then
                    atualizar_configuracao "PASTA_ALVO" "$novo_caminho" "$APP_DIR"
                    exibir_texto_digitando "Diretório de documentos atualizado para: $novo_caminho"
                else
                    echo -e "${RED}Erro: O diretório informado não existe ou é inválido.${NC}" >&2
                fi
                read -p "Pressione [Enter] para retornar ao menu..."
                ;;
            5)
                limpar_tela_retro
                echo -e "${GREEN}Informações do Sistema & Hardware${NC}"
                echo "--------------------------------------------------"
                echo "Sistema Operacional: $(uname -s) ($(uname -m))"
                echo "Modelo RAG ativo: $MODELO_IA"
                echo "Modelo Embedding ativo: $MODELO_EMBEDDING"
                echo "Diretório de Documentos: $PASTA_ALVO"
                echo "Ollama URL: $OLLAMA_URL"
                echo "--------------------------------------------------"
                read -p "Pressione [Enter] para retornar ao menu..."
                ;;
            6)
                limpar_tela_retro
                exibir_texto_digitando "Saindo do AI-JusRAG. Até logo!"
                echo ""
                exit 0
                ;;
            *)
                echo -e "${RED}Opção inválida. Tente novamente.${NC}" >&2
                sleep 1
                ;;
        esac
    done
}

# Inicializa o loop do menu principal
menu_principal

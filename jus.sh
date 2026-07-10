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
        echo -e "  ${GREEN}6)${NC} Configurações Avançadas"
        echo -e "  ${GREEN}7)${NC} Sair do Sistema"
        echo -e ""
        echo -e "${GREEN}=========================================================================${NC}"
        
        local opcao
        read -p "Digite a opção desejada (1-7): " opcao
        
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
                    
                    # 2. Busca trechos semelhantes (passa a query original para filtro de acervo)
                    local trechos
                    trechos=$(buscar_trechos_relevantes "$vetor_query" "$query" 2>/dev/null || echo "[]")
                    
                    # Exibe fontes localizadas para transparência de RAG
                    local fontes
                    fontes=$(echo "$trechos" | jq -r '.[] | .caminho' 2>/dev/null | awk -F/ '{print $NF}' | sort -u | paste -sd ", " - || echo "")
                    if [ -n "$fontes" ]; then
                        echo -e "${BLUE}[Fontes lidas: $fontes]${NC}"
                    fi
                    
                    # 3. Formata contexto
                    local contexto
                    contexto=$(echo "$trechos" | jq -r '.[] | "Arquivo: " + .caminho + "\nTrecho: " + .texto + "\n---"' 2>/dev/null || echo "")
                    
                    # Consulta estatísticas do acervo local no SQLite para evitar alucinações da IA
                    local db_path
                    db_path=$(obter_db_path)
                    local total_arquivos
                    total_arquivos=$(sqlite3 "$db_path" "SELECT COUNT(DISTINCT caminho_arquivo) FROM document_chunks;" 2>/dev/null || echo "0")
                    local arquivos_nomes
                    arquivos_nomes=$(sqlite3 "$db_path" "SELECT DISTINCT caminho_arquivo FROM document_chunks;" 2>/dev/null | awk -F/ '{print $NF}' | sort -u | paste -sd ", " - || echo "")

                    # 4. Monta o prompt RAG
                    local prompt
                    if [ -n "$contexto" ]; then
                        prompt="Você é um assistente jurídico especialista de elite. Baseado nos trechos de documentos fornecidos abaixo e nos metadados reais do acervo local, responda de forma clara e objetiva à pergunta do usuário.

Metadados do Acervo Local:
- Total de arquivos jurídicos indexados: $total_arquivos
- Nomes dos arquivos no acervo: $arquivos_nomes

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
                # Abre o sub-menu de Configurações Avançadas
                menu_configuracoes_avancadas
                ;;
            7)
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

# Sub-menu interativo de Configurações Avançadas
menu_configuracoes_avancadas() {
    while true; do
        limpar_tela_retro
        echo -e "${GREEN}=========================================================================${NC}"
        echo -e "${GREEN}                     CONFIGURAÇÕES AVANÇADAS                             ${NC}"
        echo -e "${GREEN}=========================================================================${NC}"
        echo -e "  1) Alterar Temperatura da IA [Atual: ${BLUE}$TEMPERATURA${NC}] (0.0 = preciso, 0.7 = criativo)"
        echo -e "  2) Alterar Tamanho do Bloco / Chunk Size [Atual: ${BLUE}$CHUNK_SIZE${NC}] (caracteres)"
        echo -e "  3) Alterar Sobreposição de Bloco / Chunk Overlap [Atual: ${BLUE}$CHUNK_OVERLAP${NC}] (caracteres)"
        echo -e "  4) Alterar Tamanho Máximo de Arquivo [Atual: ${BLUE}$MAX_FILE_SIZE_MB MB${NC}]"
        echo -e "  5) Alterar Modelo de Embedding [Atual: ${BLUE}$MODELO_EMBEDDING${NC}]"
        echo -e "  6) Voltar ao Menu Principal"
        echo -e ""
        echo -e "${GREEN}=========================================================================${NC}"
        
        local opcao_avancada
        read -p "Digite a opção desejada (1-6): " opcao_avancada
        
        case "$opcao_avancada" in
            1)
                limpar_tela_retro
                echo -e "${GREEN}Alterar Temperatura da IA${NC}"
                echo -e "A temperatura determina o nível de criatividade da IA (0.0 = literal/fiel, 1.0 = muito criativo)."
                local nova_temp
                read -p "Digite o novo valor (0.0 a 1.0) (atual '$TEMPERATURA'): " nova_temp
                if [ -n "$nova_temp" ]; then
                    atualizar_configuracao "TEMPERATURA" "$nova_temp" "$APP_DIR"
                    exibir_texto_digitando "Temperatura atualizada para: $nova_temp"
                fi
                read -p "Pressione [Enter] para continuar..."
                ;;
            2)
                limpar_tela_retro
                echo -e "${GREEN}Alterar Tamanho do Bloco (Chunk Size)${NC}"
                echo -e "Tamanho em caracteres para fatiar cada documento (padrão: 1000)."
                local novo_size
                read -p "Digite o novo valor (atual '$CHUNK_SIZE'): " novo_size
                if [ -n "$novo_size" ]; then
                    atualizar_configuracao "CHUNK_SIZE" "$novo_size" "$APP_DIR"
                    exibir_texto_digitando "Tamanho do bloco atualizado para: $novo_size"
                fi
                read -p "Pressione [Enter] para continuar..."
                ;;
            3)
                limpar_tela_retro
                echo -e "${GREEN}Alterar Sobreposição de Bloco (Chunk Overlap)${NC}"
                echo -e "Sobreposição de caracteres entre blocos para manter o contexto (padrão: 200)."
                local novo_overlap
                read -p "Digite o novo valor (atual '$CHUNK_OVERLAP'): " novo_overlap
                if [ -n "$novo_overlap" ]; then
                    atualizar_configuracao "CHUNK_OVERLAP" "$novo_overlap" "$APP_DIR"
                    exibir_texto_digitando "Sobreposição atualizada para: $novo_overlap"
                fi
                read -p "Pressione [Enter] para continuar..."
                ;;
            4)
                limpar_tela_retro
                echo -e "${GREEN}Alterar Tamanho Máximo de Arquivo${NC}"
                echo -e "Arquivos maiores que este limite serão ignorados na indexação."
                local novo_max
                read -p "Digite o tamanho limite em MB (atual '$MAX_FILE_SIZE_MB'): " novo_max
                if [ -n "$novo_max" ]; then
                    atualizar_configuracao "MAX_FILE_SIZE_MB" "$novo_max" "$APP_DIR"
                    exibir_texto_digitando "Tamanho limite atualizado para: $novo_max MB"
                fi
                read -p "Pressione [Enter] para continuar..."
                ;;
            5)
                limpar_tela_retro
                echo -e "${GREEN}Alterar Modelo de Embedding${NC}"
                echo -e "Modelo usado para calcular os vetores (padrão: nomic-embed-text)."
                local novo_embed
                read -p "Digite o nome do novo modelo (atual '$MODELO_EMBEDDING'): " novo_embed
                if [ -n "$novo_embed" ]; then
                    atualizar_configuracao "MODELO_EMBEDDING" "$novo_embed" "$APP_DIR"
                    exibir_texto_digitando "Modelo de embedding atualizado para: $novo_embed"
                fi
                read -p "Pressione [Enter] para continuar..."
                ;;
            6)
                break
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

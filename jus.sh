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
# Detecta RAGSEC_MODE diretamente do config.conf ANTES de sourcear qualquer módulo,
# pois carregar_configuracoes() só roda depois - os módulos de governança
# (rbac/auth/dlp/audit) só são sourceados quando o modo está ativo, mantendo a
# build jurídica padrão (RAGSEC_MODE=0) inteiramente livre desse código extra.
_ragsec_mode_detectado=$(grep -E '^RAGSEC_MODE=' "$APP_DIR/config.conf" 2>/dev/null | head -n 1 | cut -d'=' -f2 | tr -d '"'"'"' \t')

modulos=("config.sh" "ui.sh" "ai.sh" "ingest.sh" "vector.sh")
if [ "$_ragsec_mode_detectado" = "1" ]; then
    modulos+=("rbac.sh" "auth.sh" "dlp.sh" "audit.sh")
fi

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

# 2b. Gate de autenticação RAGSEC - roda ANTES do menu principal.
# Quando RAGSEC_MODE=0 este bloco inteiro é ignorado (compatibilidade retroativa).
if [ "${RAGSEC_MODE:-0}" = "1" ]; then
    mkdir -p "$CACHE_DIR"
    inicializar_banco_vetorial   # aplica migrações idempotentes (usuarios/dlp_rules/audit_log/...)
    _ragsec_seed_dlp_rules       # semeia regras DLP padrão na primeira execução

    if ! validar_sessao; then
        limpar_tela_retro
        exibir_cabecalho
        echo -e "${YELLOW}[RAGSEC] Autenticação obrigatória para continuar.${NC}"
        if ! login_usuario; then
            echo -e "${RED}[ERRO] Não foi possível autenticar. Encerrando.${NC}" >&2
            exit 1
        fi
    fi
fi

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
        exibir_menu_ragsec_extra
        echo -e "  ${GREEN}7)${NC} Sair do Sistema"
        echo -e ""
        echo -e "${GREEN}=========================================================================${NC}"

        local opcao
        read -p "Digite a opção desejada: " opcao

        case "$opcao" in
            1)
                # Gate server-side do RAGSEC: revalida sessão e bloqueia o papel 'auditor'
                # (que só tem acesso ao log de auditoria, nunca a conteúdo) mesmo que a
                # opção de menu esteja visível - o menu é conveniência, não o controle.
                if [ "${RAGSEC_MODE:-0}" = "1" ]; then
                    if ! validar_sessao; then
                        echo -e "${RED}[ERRO] Sessão inválida ou expirada. Faça login novamente (opção L).${NC}" >&2
                        sleep 2
                        continue
                    fi
                    if [ "${RAGSEC_ROLE:-}" = "auditor" ]; then
                        echo -e "${RED}[ERRO] O papel 'auditor' não tem permissão para consultar conteúdo. Use a opção de Log de Auditoria.${NC}" >&2
                        sleep 2
                        continue
                    fi
                fi

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

                    if [ "${RAGSEC_MODE:-0}" = "1" ]; then
                        # RAGSEC: a resposta precisa ser bufferizada (não streamada direto)
                        # para que o DLP possa varrê-la ANTES de ser exibida ao usuário, e
                        # para que a auditoria seja registrada antes da exibição da resposta.
                        local resposta_bruta
                        resposta_bruta=$(perguntar_ollama "$prompt" 2>/dev/null)

                        executar_dlp_pos_geracao "$resposta_bruta"

                        local docs_json max_score
                        docs_json=$(echo "$trechos" | jq -c '[.[].caminho] | unique' 2>/dev/null || echo "[]")
                        max_score=$(echo "$trechos" | jq -r '[.[].score] | max // 0' 2>/dev/null || echo "0")

                        registrar_auditoria "$RAGSEC_USER" "$RAGSEC_ROLE" "$query" "$docs_json" "$max_score" "$DLP_ACAO" "$DLP_REGRA"

                        echo -e "\n${GREEN_BOLD}RAGSEC (Resposta):${NC}"
                        if [ "$DLP_ACAO" = "block" ]; then
                            echo -e "${RED}${DLP_RESPOSTA_FINAL}${NC}"
                        elif [ "$DLP_ACAO" = "redact" ]; then
                            echo -e "${YELLOW}[DLP] Trechos sensíveis foram redigidos nesta resposta.${NC}"
                            echo -e "${GREEN}${DLP_RESPOSTA_FINAL}${NC}"
                        else
                            echo -e "${GREEN}${DLP_RESPOSTA_FINAL}${NC}"
                        fi
                    else
                        echo -e "\n${GREEN_BOLD}AI-JusRAG (Resposta):${NC}"
                        perguntar_ollama "$prompt"
                    fi
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
                echo ""

                if ! ollama list &>/dev/null; then
                    echo -e "${YELLOW}⚠️  Ollama não está em execução${NC}"
                    echo ""
                    echo -e "Modelo de IA atualmente configurado: ${BLUE}$MODELO_IA${NC}"
                    echo ""
                    echo -e "${YELLOW}Por favor, inicie o Ollama e retorne a esta opção para alterar o modelo.${NC}"
                    echo ""
                    echo -e "Para iniciar o Ollama:"
                    echo -e "  - macOS/Linux: ${GREEN}ollama serve${NC}"
                    echo -e "  - Docker: ${GREEN}bash web/run_dual_ollama.sh${NC}"
                    echo ""
                    read -p "Pressione [Enter] para retornar ao menu..."
                else
                    echo -e "${BLUE}Modelos instalados:${NC}"

                    local -a modelos_array
                    local -i contador=1

                    while IFS= read -r linha; do
                        [ -z "$linha" ] && continue
                        [[ "$linha" == NAME* ]] && continue

                        local modelo_nome=$(echo "$linha" | awk '{print $1}')
                        [ -z "$modelo_nome" ] && continue

                        modelos_array+=("$modelo_nome")
                        printf "  ${GREEN}%2d)${NC} %s\n" "$contador" "$modelo_nome"
                        ((contador++))
                    done < <(ollama list)

                    echo ""
                    echo -e "${BLUE}Ou digite o nome de um modelo para baixar:${NC}"
                    echo "Exemplos: qwen2.5:7b, qwen2.5:1.5b, llama3:8b, phi3"
                    echo ""

                    local novo_modelo
                    read -p "Escolha o número ou digite o nome do modelo (Enter para manter '$MODELO_IA'): " novo_modelo

                    if [[ "$novo_modelo" =~ ^[0-9]+$ ]] && [ "$novo_modelo" -ge 1 ] && [ "$novo_modelo" -le "${#modelos_array[@]}" ]; then
                        novo_modelo="${modelos_array[$((novo_modelo - 1))]}"
                    fi

                    if [ -n "$novo_modelo" ]; then
                        atualizar_configuracao "MODELO_IA" "$novo_modelo" "$APP_DIR"
                        exibir_texto_digitando "Configuração atualizada: MODELO_IA=$novo_modelo"
                    fi
                    read -p "Pressione [Enter] para retornar ao menu..."
                fi
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
            L|l)
                if [ "${RAGSEC_MODE:-0}" != "1" ]; then
                    echo -e "${RED}Opção inválida. Tente novamente.${NC}" >&2
                    sleep 1
                else
                    limpar_tela_retro
                    exibir_cabecalho
                    if [ -n "${RAGSEC_USER:-}" ]; then
                        logout_usuario
                    fi
                    login_usuario || echo -e "${RED}[ERRO] Login não realizado.${NC}" >&2
                    read -p "Pressione [Enter] para continuar..."
                fi
                ;;
            U|u)
                if [ "${RAGSEC_MODE:-0}" != "1" ]; then
                    echo -e "${RED}Opção inválida. Tente novamente.${NC}" >&2
                    sleep 1
                elif ! validar_sessao || [ "${RAGSEC_ROLE:-}" != "exec" ]; then
                    echo -e "${RED}[ERRO] Acesso negado. Esta ação requer o papel 'exec'.${NC}" >&2
                    sleep 2
                else
                    menu_gerenciar_usuarios
                fi
                ;;
            C|c)
                if [ "${RAGSEC_MODE:-0}" != "1" ]; then
                    echo -e "${RED}Opção inválida. Tente novamente.${NC}" >&2
                    sleep 1
                elif ! validar_sessao || { [ "${RAGSEC_ROLE:-}" != "exec" ] && [ "${RAGSEC_ROLE:-}" != "manager" ]; }; then
                    echo -e "${RED}[ERRO] Acesso negado. Esta ação requer o papel 'exec' ou 'manager'.${NC}" >&2
                    sleep 2
                else
                    menu_classificacao_documentos
                fi
                ;;
            D|d)
                if [ "${RAGSEC_MODE:-0}" != "1" ]; then
                    echo -e "${RED}Opção inválida. Tente novamente.${NC}" >&2
                    sleep 1
                elif ! validar_sessao || [ "${RAGSEC_ROLE:-}" != "exec" ]; then
                    echo -e "${RED}[ERRO] Acesso negado. Esta ação requer o papel 'exec'.${NC}" >&2
                    sleep 2
                else
                    menu_regras_dlp
                fi
                ;;
            A|a)
                if [ "${RAGSEC_MODE:-0}" != "1" ]; then
                    echo -e "${RED}Opção inválida. Tente novamente.${NC}" >&2
                    sleep 1
                elif ! validar_sessao || [ "${RAGSEC_ROLE:-}" != "auditor" ]; then
                    echo -e "${RED}[ERRO] Acesso negado. Esta ação requer o papel 'auditor'.${NC}" >&2
                    sleep 2
                else
                    menu_ver_auditoria
                fi
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

# =========================================================================
# RAGSEC - Sub-menus administrativos (só chamados após gate de papel em
# menu_principal; cada função revalida a sessão de novo antes de qualquer
# ação mutável, pois o menu é conveniência - não é o controle de acesso).
# =========================================================================

# [Admin] Gerenciamento de Usuários (exec)
menu_gerenciar_usuarios() {
    local db_path
    db_path=$(obter_db_path)

    while true; do
        if ! validar_sessao || [ "${RAGSEC_ROLE:-}" != "exec" ]; then
            echo -e "${RED}[ERRO] Sessão expirada ou papel insuficiente.${NC}" >&2
            return
        fi

        limpar_tela_retro
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo -e "${GREEN_BOLD}                  [ADMIN] GERENCIAMENTO DE USUÁRIOS                      ${NC}"
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        sqlite3 -header -column "$db_path" "SELECT id, username, role, clearance, ativo FROM usuarios ORDER BY id;" 2>/dev/null
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo -e "  1) Adicionar novo usuário"
        echo -e "  2) Ativar/Desativar usuário por id"
        echo -e "  3) Voltar"
        local op
        read -p "Opção: " op

        case "$op" in
            1)
                local novo_user nova_senha novo_role nova_clearance
                read -p "Novo username: " novo_user
                read -s -p "Senha: " nova_senha
                echo ""
                read -p "Papel (engineer/manager/exec/auditor): " novo_role
                case "$novo_role" in
                    engineer|manager|exec|auditor) ;;
                    *) echo -e "${RED}[ERRO] Papel inválido.${NC}" >&2; read -p "Pressione [Enter]..."; continue ;;
                esac
                nova_clearance=$(obter_clearance_papel "$novo_role")

                if [ -z "$novo_user" ] || [ -z "$nova_senha" ]; then
                    echo -e "${RED}[ERRO] Username/senha não podem ser vazios.${NC}" >&2
                else
                    local hash_senha user_esc hash_esc
                    hash_senha=$(_ragsec_hash_senha "$nova_senha")
                    user_esc=$(_ragsec_escapar_sql "$novo_user")
                    hash_esc=$(_ragsec_escapar_sql "$hash_senha")
                    if sqlite3 "$db_path" "INSERT INTO usuarios (username, senha_hash, role, clearance) VALUES ('$user_esc', '$hash_esc', '$novo_role', $nova_clearance);" 2>/dev/null; then
                        echo -e "${GREEN}[OK] Usuário '$novo_user' criado com papel '$novo_role'.${NC}"
                    else
                        echo -e "${RED}[ERRO] Falha ao criar usuário (username já existe?).${NC}" >&2
                    fi
                fi
                read -p "Pressione [Enter] para continuar..."
                ;;
            2)
                local id_alvo estado_atual
                read -p "ID do usuário: " id_alvo
                if [[ "$id_alvo" =~ ^[0-9]+$ ]]; then
                    estado_atual=$(sqlite3 "$db_path" "SELECT ativo FROM usuarios WHERE id = $id_alvo;" 2>/dev/null || echo "")
                    if [ -z "$estado_atual" ]; then
                        echo -e "${RED}[ERRO] Usuário não encontrado.${NC}" >&2
                    else
                        local novo_estado=1
                        [ "$estado_atual" = "1" ] && novo_estado=0
                        sqlite3 "$db_path" "UPDATE usuarios SET ativo = $novo_estado WHERE id = $id_alvo;" 2>/dev/null
                        echo -e "${GREEN}[OK] Usuário id=$id_alvo agora está $( [ "$novo_estado" = "1" ] && echo "ativo" || echo "desativado").${NC}"
                    fi
                else
                    echo -e "${RED}[ERRO] ID inválido.${NC}" >&2
                fi
                read -p "Pressione [Enter] para continuar..."
                ;;
            3) return ;;
            *) echo -e "${RED}Opção inválida.${NC}" >&2; sleep 1 ;;
        esac
    done
}

# [Admin] Gerenciador de Classificação de Documentos (exec/manager)
menu_classificacao_documentos() {
    local db_path
    db_path=$(obter_db_path)

    while true; do
        if ! validar_sessao || { [ "${RAGSEC_ROLE:-}" != "exec" ] && [ "${RAGSEC_ROLE:-}" != "manager" ]; }; then
            echo -e "${RED}[ERRO] Sessão expirada ou papel insuficiente.${NC}" >&2
            return
        fi

        limpar_tela_retro
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo -e "${GREEN_BOLD}            [ADMIN] GERENCIADOR DE CLASSIFICAÇÃO DE DOCUMENTOS           ${NC}"
        echo -e "${GREEN_BOLD}=========================================================================${NC}"

        local arquivos
        arquivos=$(sqlite3 "$db_path" "SELECT DISTINCT caminho_arquivo, classificacao FROM document_chunks ORDER BY caminho_arquivo;" 2>/dev/null)

        if [ -z "$arquivos" ]; then
            echo -e "${YELLOW}(Nenhum documento indexado ainda. Rode a sincronização primeiro.)${NC}"
            echo ""
            read -p "Pressione [Enter] para voltar..."
            return
        fi

        local -a caminhos=()
        local i=0
        while IFS='|' read -r caminho classe || [ -n "$caminho" ]; do
            [ -z "$caminho" ] && continue
            i=$((i+1))
            caminhos+=("$caminho")
            echo -e "  ${GREEN}$i)${NC} [${BLUE}$classe${NC}] $caminho"
        done <<< "$arquivos"

        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo -e "  0) Voltar"
        local escolha
        read -p "Selecione o número do arquivo para reclassificar (ou 0 para voltar): " escolha

        if [ "$escolha" = "0" ]; then
            return
        fi

        if ! [[ "$escolha" =~ ^[0-9]+$ ]] || [ "$escolha" -lt 1 ] || [ "$escolha" -gt "${#caminhos[@]}" ]; then
            echo -e "${RED}[ERRO] Seleção inválida.${NC}" >&2
            sleep 1
            continue
        fi

        local caminho_alvo="${caminhos[$((escolha-1))]}"
        echo -e "Arquivo selecionado: ${BLUE}$caminho_alvo${NC}"
        local nova_classe
        read -p "Nova classificação (public/internal/confidential/secret): " nova_classe

        case "$nova_classe" in
            public|internal|confidential|secret) ;;
            *) echo -e "${RED}[ERRO] Classificação inválida.${NC}" >&2; read -p "Pressione [Enter]..."; continue ;;
        esac

        # Managers não podem elevar/classificar documentos como 'secret' (só exec pode)
        if [ "$nova_classe" = "secret" ] && [ "${RAGSEC_ROLE:-}" != "exec" ]; then
            echo -e "${RED}[ERRO] Apenas o papel 'exec' pode classificar documentos como 'secret'.${NC}" >&2
            read -p "Pressione [Enter] para continuar..."
            continue
        fi

        local nivel caminho_esc classe_esc user_esc
        nivel=$(obter_nivel_classificacao "$nova_classe")
        caminho_esc=$(_ragsec_escapar_sql "$caminho_alvo")
        classe_esc=$(_ragsec_escapar_sql "$nova_classe")
        user_esc=$(_ragsec_escapar_sql "${RAGSEC_USER:-desconhecido}")

        sqlite3 "$db_path" "UPDATE document_chunks SET classificacao = '$classe_esc' WHERE caminho_arquivo = '$caminho_esc';" 2>/dev/null
        sqlite3 "$db_path" "INSERT INTO doc_classificacao (caminho_arquivo, classificacao, nivel, classificado_por) VALUES ('$caminho_esc', '$classe_esc', $nivel, '$user_esc')
            ON CONFLICT(caminho_arquivo) DO UPDATE SET classificacao = excluded.classificacao, nivel = excluded.nivel, classificado_por = excluded.classificado_por, classificado_em = datetime('now');" 2>/dev/null

        echo -e "${GREEN}[OK] '$caminho_alvo' reclassificado como '$nova_classe'.${NC}"
        read -p "Pressione [Enter] para continuar..."
    done
}

# [Admin] Regras de DLP (exec)
menu_regras_dlp() {
    local db_path
    db_path=$(obter_db_path)

    while true; do
        if ! validar_sessao || [ "${RAGSEC_ROLE:-}" != "exec" ]; then
            echo -e "${RED}[ERRO] Sessão expirada ou papel insuficiente.${NC}" >&2
            return
        fi

        limpar_tela_retro
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo -e "${GREEN_BOLD}                       [ADMIN] REGRAS DE DLP                             ${NC}"
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        sqlite3 -header -column "$db_path" "SELECT id, acao, ativo, padrao FROM dlp_rules ORDER BY id;" 2>/dev/null
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo -e "  1) Adicionar nova regra"
        echo -e "  2) Ativar/Desativar regra por id"
        echo -e "  3) Voltar"
        local op
        read -p "Opção: " op

        case "$op" in
            1)
                local novo_id novo_padrao nova_acao
                read -p "ID da regra (curto, ex: my_rule): " novo_id
                read -p "Padrão (regex PCRE): " novo_padrao
                read -p "Ação (redact/block): " nova_acao
                case "$nova_acao" in
                    redact|block) ;;
                    *) echo -e "${RED}[ERRO] Ação inválida.${NC}" >&2; read -p "Pressione [Enter]..."; continue ;;
                esac
                if [ -z "$novo_id" ] || [ -z "$novo_padrao" ]; then
                    echo -e "${RED}[ERRO] ID/padrão não podem ser vazios.${NC}" >&2
                else
                    local id_esc padrao_esc acao_esc
                    id_esc=$(_ragsec_escapar_sql "$novo_id")
                    padrao_esc=$(_ragsec_escapar_sql "$novo_padrao")
                    acao_esc=$(_ragsec_escapar_sql "$nova_acao")
                    if sqlite3 "$db_path" "INSERT INTO dlp_rules (id, padrao, acao) VALUES ('$id_esc', '$padrao_esc', '$acao_esc');" 2>/dev/null; then
                        echo -e "${GREEN}[OK] Regra '$novo_id' adicionada.${NC}"
                    else
                        echo -e "${RED}[ERRO] Falha ao adicionar regra (id já existe?).${NC}" >&2
                    fi
                fi
                read -p "Pressione [Enter] para continuar..."
                ;;
            2)
                local id_regra estado_atual
                read -p "ID da regra: " id_regra
                local id_regra_esc
                id_regra_esc=$(_ragsec_escapar_sql "$id_regra")
                estado_atual=$(sqlite3 "$db_path" "SELECT ativo FROM dlp_rules WHERE id = '$id_regra_esc';" 2>/dev/null || echo "")
                if [ -z "$estado_atual" ]; then
                    echo -e "${RED}[ERRO] Regra não encontrada.${NC}" >&2
                else
                    local novo_estado=1
                    [ "$estado_atual" = "1" ] && novo_estado=0
                    sqlite3 "$db_path" "UPDATE dlp_rules SET ativo = $novo_estado WHERE id = '$id_regra_esc';" 2>/dev/null
                    echo -e "${GREEN}[OK] Regra '$id_regra' agora está $( [ "$novo_estado" = "1" ] && echo "ativa" || echo "desativada").${NC}"
                fi
                read -p "Pressione [Enter] para continuar..."
                ;;
            3) return ;;
            *) echo -e "${RED}Opção inválida.${NC}" >&2; sleep 1 ;;
        esac
    done
}

# [Auditor] Visualização do Log de Auditoria (auditor)
menu_ver_auditoria() {
    local db_path
    db_path=$(obter_db_path)

    while true; do
        if ! validar_sessao || [ "${RAGSEC_ROLE:-}" != "auditor" ]; then
            echo -e "${RED}[ERRO] Sessão expirada ou papel insuficiente.${NC}" >&2
            return
        fi

        limpar_tela_retro
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo -e "${GREEN_BOLD}                     [AUDITOR] LOG DE AUDITORIA                          ${NC}"
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo -e "  1) Ver últimas 25 entradas"
        echo -e "  2) Filtrar por usuário"
        echo -e "  3) Purgar entradas antigas (retenção: ${AUDIT_RETENTION_DIAS:-365} dias)"
        echo -e "  4) Voltar"
        local op
        read -p "Opção: " op

        case "$op" in
            1)
                limpar_tela_retro
                sqlite3 -header -column "$db_path" \
                    "SELECT id, ts, username, role, substr(query_text,1,40) AS query, dlp_action, dlp_rule FROM audit_log ORDER BY id DESC LIMIT 25;" 2>/dev/null
                echo ""
                read -p "Pressione [Enter] para continuar..."
                ;;
            2)
                local user_filtro user_filtro_esc
                read -p "Username a filtrar: " user_filtro
                user_filtro_esc=$(_ragsec_escapar_sql "$user_filtro")
                limpar_tela_retro
                sqlite3 -header -column "$db_path" \
                    "SELECT id, ts, username, role, substr(query_text,1,40) AS query, dlp_action, dlp_rule FROM audit_log WHERE username = '$user_filtro_esc' ORDER BY id DESC LIMIT 50;" 2>/dev/null
                echo ""
                read -p "Pressione [Enter] para continuar..."
                ;;
            3)
                purgar_auditoria
                read -p "Pressione [Enter] para continuar..."
                ;;
            4) return ;;
            *) echo -e "${RED}Opção inválida.${NC}" >&2; sleep 1 ;;
        esac
    done
}

# Inicializa o loop do menu principal
menu_principal

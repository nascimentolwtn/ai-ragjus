#!/bin/bash
# =========================================================================
# AI-RAGJus Setup / Provisioning Script (Interactive & Guided)
# =========================================================================
set -eo pipefail

# Configuração de Log Geral da Instalação (Grava tudo linha a linha no setup.log)
LOG_FILE="setup.log"
echo "=== LOG DE INSTALAÇÃO AI-RAGJUS - $(date) ===" > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1


# Configurações de Cores para Terminal
GREEN='\033[0;32m'
GREEN_BOLD='\033[1;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem Cor

# Detecção de execução externa (ex: curl -sSL ... | bash)
CLONED=false
if [ ! -f "jus.sh" ]; then
    echo -e "${YELLOW}[INFO] Script executado externamente. Configurando o ambiente de trabalho...${NC}"
    if ! command -v git &> /dev/null; then
        echo -e "${RED}[ERRO] Git não está instalado. Por favor, instale o Git e tente novamente.${NC}" >&2
        exit 1
    fi
    echo -e "${BLUE}Clonando o repositório 'ai-ragjus' no diretório atual...${NC}"
    git clone https://github.com/fraconca/ai-ragjus.git
    cd ai-ragjus
    CLONED=true
fi

# Helper robusto para ler input tanto em execução local quanto via curl | bash
ler_entrada() {
    local prompt_msg="$1"
    local resultado_var="$2"
    
    if [ -t 0 ]; then
        # Stdin é um terminal interativo comum (execução local)
        if [ -n "$resultado_var" ]; then
            read -p "$prompt_msg" "$resultado_var"
        else
            read -p "$prompt_msg"
        fi
    else
        # Stdin é um pipe (curl | bash). Tenta ler de /dev/tty se disponível e acessível
        if [ -r /dev/tty ] && [ -w /dev/tty ]; then
            if [ -n "$resultado_var" ]; then
                read -p "$prompt_msg" "$resultado_var" < /dev/tty
            else
                read -p "$prompt_msg" < /dev/tty
            fi
        else
            # Caso extremo sem tty acessível (fallback)
            if [ -n "$resultado_var" ]; then
                read -p "$prompt_msg" "$resultado_var"
            else
                read -p "$prompt_msg"
            fi
        fi
    fi
}

# 1. Termos e Condições / Disclaimer de Privacidade
limpar_tela() {
    clear 2>/dev/null || echo -ne "\033[H\033[2J"
}

limpar_tela
echo -e "${GREEN_BOLD}=========================================================================${NC}"
echo -e "${GREEN_BOLD}             TERMO DE COMPROMISSO DE PRIVACIDADE E USO                   ${NC}"
echo -e "${GREEN_BOLD}=========================================================================${NC}"
echo -e " O AI-RAGJus foi projetado especificamente para operar em regime de"
echo -e " ${GREEN_BOLD}TOTAL ISOLAMENTO DE REDE (100% offline e air-gapped)${NC}."
echo -e ""
echo -e " 1. ${GREEN_BOLD}Privacidade Absoluta:${NC} Suas peças processuais, contratos confidenciais"
echo -e "    e segredos de justiça serão processados estritamente na sua máquina."
echo -e " 2. ${GREEN_BOLD}Ausência de Vazamentos:${NC} Nenhuma informação é enviada a nuvens públicas"
echo -e "    ou APIs de terceiros. Todo o processamento vetorial ocorre localmente."
echo -e " 3. ${GREEN_BOLD}Responsabilidade Local:${NC} O usuário é responsável por garantir que as"
echo -e "    dependências de sistema sejam instaladas a partir de fontes seguras."
echo -e "${GREEN_BOLD}=========================================================================${NC}"
echo ""

ler_entrada "Você leu, concorda com os termos de privacidade local e deseja continuar? (s/n): " termo_aceito
if [ "$termo_aceito" != "s" ] && [ "$termo_aceito" != "S" ]; then
    echo -e "\n${RED}Instalação cancelada. O AI-RAGJus requer a aceitação dos termos para continuar.${NC}"
    exit 0
fi

# 2. Verificação de Hardware (RAM)
limpar_tela
echo -e "${GREEN}=========================================================================${NC}"
echo -e "${GREEN}                  [PASSO 1/4] Recursos do Sistema                       ${NC}"
echo -e "${GREEN}=========================================================================${NC}"
OS_TYPE="$(uname -s)"
RAM_GB=0

if [ "$OS_TYPE" = "Darwin" ]; then
    RAM_BYTES=$(sysctl -n hw.memsize || echo 0)
    RAM_GB=$((RAM_BYTES / 1024 / 1024 / 1024))
elif [ "$OS_TYPE" = "Linux" ]; then
    if [ -f /proc/meminfo ]; then
        RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        RAM_GB=$((RAM_KB / 1024 / 1024))
    fi
fi

echo -e "Memória RAM detectada: ${BLUE}${RAM_GB} GB${NC}"
if [ "$RAM_GB" -lt 4 ]; then
    echo -e "${RED}[AVISO] Seu sistema possui recursos muito limitados (${RAM_GB}GB).${NC}"
    echo -e "Será obrigatório utilizar modelos ultraleves (ex: qwen2.5:1.5b) para evitar travamentos."
    MODELO_SUGERIDO="qwen2.5:1.5b"
elif [ "$RAM_GB" -lt 8 ]; then
    echo -e "${YELLOW}[AVISO] Memória RAM menor que 8GB (${RAM_GB}GB).${NC}"
    echo -e "Sugerimos o uso do modelo mais leve para garantir fluidez."
    MODELO_SUGERIDO="qwen2.5:1.5b"
else
    echo -e "${GREEN}[OK] Recursos de hardware excelentes para o modelo padrão (7B).${NC}"
    MODELO_SUGERIDO="qwen2.5:7b"
fi
echo ""
ler_entrada "Pressione [Enter] para prosseguir..."

# 3. Verificação de Dependências Básicas
while true; do
    limpar_tela
    echo -e "${GREEN}=========================================================================${NC}"
    echo -e "${GREEN}                  [PASSO 2/4] Ferramentas de Sistema                      ${NC}"
    echo -e "${GREEN}=========================================================================${NC}"
    
    DEPENDENCIES=("curl" "jq" "sqlite3" "pdftotext" "pandoc")
    MISSING_DEPS=()

    for dep in "${DEPENDENCIES[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            MISSING_DEPS+=("$dep")
        fi
    done

    instalar_dependencias_automatico() {
        echo -e "\n${BLUE}Iniciando a instalação automática das dependências...${NC}"
        if [ "$OS_TYPE" = "Darwin" ]; then
            # Verifica se o Homebrew está instalado
            if ! command -v brew &> /dev/null; then
                echo -e "${YELLOW}Homebrew (gerenciador de pacotes) não foi detectado em seu Mac.${NC}"
                echo -e "O Homebrew é necessário para baixar ferramentas adicionais no macOS de forma segura."
                ler_entrada "Deseja que eu instale o Homebrew automaticamente agora? (s/n): " instalar_brew
                if [ "$instalar_brew" = "s" ] || [ "$instalar_brew" = "S" ]; then
                    echo -e "${BLUE}Baixando e instalando o Homebrew... (Isso pode solicitar confirmações no terminal)${NC}"
                    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                    # Configura as variáveis do brew na sessão atual
                    if [ -f "/opt/homebrew/bin/brew" ]; then
                        eval "$(/opt/homebrew/bin/brew shellenv)"
                    elif [ -f "/usr/local/bin/brew" ]; then
                        eval "$(/usr/local/bin/brew shellenv)"
                    fi
                else
                    echo -e "${RED}Instalação do Homebrew recusada. Por favor, instale as ferramentas manualmente.${NC}"
                    return 1
                fi
            fi

            # Instala os pacotes
            echo -e "${BLUE}Executando 'brew install poppler pandoc jq sqlite3'...${NC}"
            brew install poppler pandoc jq sqlite3
            echo -e "${GREEN}[OK] Dependências instaladas com sucesso via Homebrew!${NC}"
        else
            # Linux / WSL2
            echo -e "${BLUE}Instalando poppler-utils, pandoc, jq e sqlite3 via apt-get...${NC}"
            echo -e "${YELLOW}(Será solicitada sua senha 'sudo' do Linux/WSL2 para permissão de instalação)${NC}"
            sudo apt-get update && sudo apt-get install -y poppler-utils pandoc jq sqlite3
            echo -e "${GREEN}[OK] Dependências instaladas com sucesso via apt-get!${NC}"
        fi
    }

    if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
        echo -e "${YELLOW}[AVISO] Ferramentas essenciais ausentes: ${MISSING_DEPS[*]}${NC}"
        echo -e "Estas ferramentas servem para extrair o texto limpo de arquivos PDF/Word/PPTX localmente."
        echo ""
        
        ler_entrada "Deseja que o AI-RAGJus tente instalar estas ferramentas automaticamente para você? (s/n): " auto_instalar
        if [ "$auto_instalar" = "s" ] || [ "$auto_instalar" = "S" ]; then
            if instalar_dependencias_automatico; then
                echo -e "\n${BLUE}Reavaliando dependências instaladas...${NC}"
                sleep 1
                continue
            fi
        fi

        echo -e "\n-------------------------------------------------------------------------"
        echo -e "Caso prefira instalar manualmente no seu terminal, siga estas instruções:"
        if [ "$OS_TYPE" = "Darwin" ]; then
            echo -e "  -> No macOS (via Homebrew):"
            echo -e "     ${GREEN_BOLD}brew install poppler pandoc jq sqlite3${NC}"
        else
            echo -e "  -> No Linux/WSL (Debian/Ubuntu):"
            echo -e "     ${GREEN_BOLD}sudo apt-get update && sudo apt-get install -y poppler-utils pandoc jq sqlite3${NC}"
        fi
        echo -e "-------------------------------------------------------------------------"
        echo -e "${YELLOW}(Se as dependências não forem resolvidas, esta tela continuará reaparecendo)${NC}"
        echo ""
        ler_entrada "Pressione [Enter] para reavaliar as dependências ou digite 'c' para ignorar e continuar: " acao_dep
        if [ "$acao_dep" = "c" ] || [ "$acao_dep" = "C" ]; then
            break
        fi
        sleep 1 || true
    else
        echo -e "${GREEN}[OK] Todas as ferramentas CLI básicas estão instaladas com sucesso!${NC}"
        echo ""
        sleep 1
        break
    fi
done

# 4. Verificação do Ollama
limpar_tela
echo -e "${GREEN}=========================================================================${NC}"
echo -e "${GREEN}                  [PASSO 3/4] Conexão com Ollama Local                    ${NC}"
echo -e "${GREEN}=========================================================================${NC}"
OLLAMA_HOST="http://localhost:11434"

if ! curl -s --connect-timeout 2 "$OLLAMA_HOST" &> /dev/null; then
    echo -e "${RED}[ERRO] Não foi possível conectar ao Ollama em $OLLAMA_HOST.${NC}"
    echo -e "Por favor, abra o aplicativo do Ollama na sua máquina antes de continuar."
    echo -e "Se você não tem o Ollama instalado, baixe-o em: https://ollama.com"
    echo ""
    ler_entrada "Pressione [Enter] após iniciar o Ollama para tentar novamente..."
    if ! curl -s --connect-timeout 2 "$OLLAMA_HOST" &> /dev/null; then
        echo -e "${RED}[FALHA] Ollama continua inacessível. O instalador será encerrado.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}[OK] Conexão com o Ollama estabelecida com sucesso!${NC}"

# 5. Configuração e Confirmação de Downloads de Modelos
MODELOS_INSTALADOS=$(curl -s "$OLLAMA_HOST/api/tags" | jq -r '.models[].name' 2>/dev/null || echo "")

echo -e "\n${BLUE}Verificando modelos locais instalados no seu Ollama...${NC}"
echo -e "-------------------------------------------------------------------------"
if [ -z "$MODELOS_INSTALADOS" ]; then
    echo "  (Nenhum modelo encontrado no Ollama local)"
else
    echo "$MODELOS_INSTALADOS" | sed 's/^/  - /'
fi
echo -e "-------------------------------------------------------------------------"

DOWNLOAD_EMBED=false
DOWNLOAD_IA=false
MODELO_IA_ATIVO="$MODELO_SUGERIDO"
MODELO_EMBEDDING_ATIVO="nomic-embed-text"

# 5.1 Validação do Modelo de Embedding (nomic-embed-text)
if echo "$MODELOS_INSTALADOS" | grep -q "nomic-embed-text"; then
    EMBED_STATUS="${GREEN}[MANTIDO] nomic-embed-text (já instalado no seu computador)${NC}"
else
    echo -e "\n${YELLOW}[AVISO] O modelo de embedding 'nomic-embed-text' (obrigatório para indexação e busca vetorial) não foi encontrado.${NC}"
    ler_entrada "Deseja agendar o download deste modelo? (~270MB) (s/n): " pull_embed
    if [ "$pull_embed" = "s" ] || [ "$pull_embed" = "S" ]; then
        DOWNLOAD_EMBED=true
        EMBED_STATUS="${YELLOW}[DOWNLOAD] nomic-embed-text (~270MB)${NC}"
    else
        EMBED_STATUS="${RED}[PULADO] nomic-embed-text (o sistema não funcionará sem este modelo)${NC}"
    fi
fi

# 5.2 Validação do Modelo Lógico (Inference)
if echo "$MODELOS_INSTALADOS" | grep -q "$MODELO_SUGERIDO"; then
    IA_STATUS="${GREEN}[MANTIDO] $MODELO_SUGERIDO (já instalado no seu computador)${NC}"
    MODELO_IA_ATIVO="$MODELO_SUGERIDO"
else
    echo -e "\n${YELLOW}[INFO] O modelo lógico recomendado para seu hardware é '$MODELO_SUGERIDO' (não instalado).${NC}"
    ler_entrada "Deseja agendar o download deste modelo? (s/n): " pull_logic
    
    if [ "$pull_logic" = "s" ] || [ "$pull_logic" = "S" ]; then
        DOWNLOAD_IA=true
        IA_STATUS="${YELLOW}[DOWNLOAD] $MODELO_SUGERIDO (~4.7GB)${NC}"
        MODELO_IA_ATIVO="$MODELO_SUGERIDO"
    else
        ler_entrada "Gostaria de informar o nome de outro modelo já instalado em seu PC para usar como padrão? (s/n): " usar_outro
        if [ "$usar_outro" = "s" ] || [ "$usar_outro" = "S" ]; then
            echo -e "Modelos locais disponíveis no seu computador:"
            echo "$MODELOS_INSTALADOS" | sed 's/^/  - /'
            ler_entrada "Digite o nome exato do modelo selecionado: " modelo_usuario
            if [ -n "$modelo_usuario" ]; then
                MODELO_IA_ATIVO="$modelo_usuario"
                IA_STATUS="${GREEN}[MANTIDO] $MODELO_IA_ATIVO (definido pelo usuário)${NC}"
            else
                IA_STATUS="${RED}[PULADO] Nenhum modelo lógico definido (configure em config.conf)${NC}"
            fi
        else
            IA_STATUS="${RED}[PULADO] Nenhum modelo lógico definido (configure em config.conf)${NC}"
        fi
    fi
fi

# 5.3 Exibição do Resumo e Confirmação de Execução
limpar_tela
echo -e "${GREEN_BOLD}=========================================================================${NC}"
echo -e "${GREEN_BOLD}             RESUMO DE AÇÕES DO OLLAMA - CONFIRMAÇÃO FINAL               ${NC}"
echo -e "${GREEN_BOLD}=========================================================================${NC}"
echo -e "  1. Indexador Vetorial (Embedding) :"
echo -e "     $EMBED_STATUS"
echo -e "  2. Cérebro de IA (Lógico/Chat)     :"
echo -e "     $IA_STATUS"
echo -e "${GREEN_BOLD}=========================================================================${NC}"
echo ""

ler_entrada "Deseja prosseguir e aplicar as ações acima? (s/n): " confirmar_acoes
if [ "$confirmar_acoes" != "s" ] && [ "$confirmar_acoes" != "S" ]; then
    echo -e "\n${RED}[CANCELADO] Nenhum modelo foi baixado ou alterado.${NC}"
    DOWNLOAD_EMBED=false
    DOWNLOAD_IA=false
fi

# Executa os downloads programados
if [ "$DOWNLOAD_EMBED" = true ]; then
    echo -e "\n${BLUE}Iniciando download do modelo nomic-embed-text...${NC}"
    curl -d '{"name": "nomic-embed-text"}' "$OLLAMA_HOST/api/pull"
    echo -e "\n${GREEN}[OK] nomic-embed-text instalado.${NC}"
fi

if [ "$DOWNLOAD_IA" = true ]; then
    echo -e "\n${BLUE}Iniciando download do modelo $MODELO_IA_ATIVO...${NC}"
    curl -d "{\"name\": \"$MODELO_IA_ATIVO\"}" "$OLLAMA_HOST/api/pull"
    echo -e "\n${GREEN}[OK] $MODELO_IA_ATIVO instalado.${NC}"
fi

echo ""
ler_entrada "Pressione [Enter] para concluir as configurações de arquivos..."

# 6. Organização de pastas e salvamento
limpar_tela
echo -e "${GREEN}=========================================================================${NC}"
echo -e "${GREEN}                  [PASSO 4/4] Gravando Configurações                      ${NC}"
echo -e "${GREEN}=========================================================================${NC}"

mkdir -p docs/leis docs/processos docs/contratos
mkdir -p .cache_vetorial
mkdir -p src

if [ ! -f "config.conf" ]; then
    cp config.conf.example config.conf
    # Atualiza as escolhas de modelo no arquivo config.conf gerado
    sed -i.bak "s/MODELO_IA=\"qwen2.5:7b\"/MODELO_IA=\"$MODELO_IA_ATIVO\"/" config.conf && rm -f config.conf.bak
    echo -e "${GREEN}[OK] Arquivo config.conf configurado com suas escolhas.${NC}"
else
    echo -e "${YELLOW}[INFO] Arquivo config.conf existente. Nenhuma variável foi sobrescrita.${NC}"
fi

echo -e "\n${GREEN_BOLD}=========================================================================${NC}"
echo -e "${GREEN_BOLD}             SETUP CONCLUÍDO COM SUCESSO PARA AI-RAGJUS!                 ${NC}"
echo -e "${GREEN_BOLD}=========================================================================${NC}"
if [ "$CLONED" = "true" ]; then
    echo -e " 1. Acesse a pasta do projeto executando: ${GREEN_BOLD}cd ai-ragjus${NC}"
    echo -e " 2. Coloque seus documentos jurídicos dentro de ${BLUE}./docs/${NC}"
    echo -e " 3. Inicie a aplicação executando: ${GREEN_BOLD}./jus.sh${NC}"
else
    echo -e " 1. Coloque seus documentos jurídicos dentro da pasta correspondente em ${BLUE}./docs/${NC}"
    echo -e " 2. Inicie a aplicação executando: ${GREEN_BOLD}./jus.sh${NC}"
fi
echo -e "${GREEN_BOLD}=========================================================================${NC}"

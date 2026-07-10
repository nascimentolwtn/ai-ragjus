#!/bin/bash
# =========================================================================
# AI-RAGJus Setup / Provisioning Script (Interactive & Guided)
# =========================================================================
set -eo pipefail

# Configurações de Cores para Terminal
GREEN='\033[0;32m'
GREEN_BOLD='\033[1;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem Cor

# Detecção de execução externa (ex: curl -sSL ... | bash)
if [ ! -f "jus.sh" ]; then
    echo -e "${YELLOW}[INFO] Script executado externamente. Configurando o ambiente de trabalho...${NC}"
    if ! command -v git &> /dev/null; then
        echo -e "${RED}[ERRO] Git não está instalado. Por favor, instale o Git e tente novamente.${NC}" >&2
        exit 1
    fi
    echo -e "${BLUE}Clonando o repositório 'ai-ragjus' no diretório atual...${NC}"
    git clone https://github.com/fraconca/ai-ragjus.git
    cd ai-ragjus
fi

# 1. Termos e Condições / Disclaimer de Privacidade
limpar_tela() {
    if command -v tput &> /dev/null; then tput clear; else echo -ne "\033[H\033[2J"; fi
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

read -p "Você leu, concorda com os termos de privacidade local e deseja continuar? (s/n): " termo_aceito
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
read -p "Pressione [Enter] para prosseguir..."

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

    if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
        echo -e "${YELLOW}[AVISO] Ferramentas essenciais ausentes: ${MISSING_DEPS[*]}${NC}"
        echo -e "Para que o leitor de PDF/Word e banco de dados funcionem, instale-os antes de continuar:"
        if [ "$OS_TYPE" = "Darwin" ]; then
            echo -e "  -> No macOS (via Homebrew):"
            echo -e "     ${GREEN_BOLD}brew install poppler pandoc jq sqlite3${NC}"
        else
            echo -e "  -> No Linux/WSL (Debian/Ubuntu):"
            echo -e "     ${GREEN_BOLD}sudo apt-get update && sudo apt-get install -y poppler-utils pandoc jq sqlite3${NC}"
        fi
        echo ""
        read -p "Pressione [Enter] para reavaliar as dependências ou digite 'c' para tentar ignorar: " acao_dep
        if [ "$acao_dep" = "c" ] || [ "$acao_dep" = "C" ]; then
            break
        fi
    else
        echo -e "${GREEN}[OK] Todas as ferramentas CLI básicas estão instaladas com sucesso!${NC}"
        echo ""
        read -p "Pressione [Enter] para prosseguir..."
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
    read -p "Pressione [Enter] após iniciar o Ollama para tentar novamente..."
    if ! curl -s --connect-timeout 2 "$OLLAMA_HOST" &> /dev/null; then
        echo -e "${RED}[FALHA] Ollama continua inacessível. O instalador será encerrado.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}[OK] Conexão com o Ollama estabelecida com sucesso!${NC}"

# 5. Download seletivo e guiado de modelos
MODELOS_INSTALADOS=$(curl -s "$OLLAMA_HOST/api/tags" | jq -r '.models[].name' 2>/dev/null || echo "")

echo -e "\n${BLUE}Verificando modelos locais instalados no seu Ollama...${NC}"
echo -e "-------------------------------------------------------------------------"
echo "$MODELOS_INSTALADOS" | sed 's/^/  - /'
echo -e "-------------------------------------------------------------------------"

MODELO_IA_ATIVO="$MODELO_SUGERIDO"
MODELO_EMBEDDING_ATIVO="nomic-embed-text"

# 5.1 Embedding Model
if echo "$MODELOS_INSTALADOS" | grep -q "nomic-embed-text"; then
    echo -e "${GREEN}[OK] Modelo de embedding 'nomic-embed-text' já está instalado.${NC}"
else
    echo -e "\n${YELLOW}O modelo de embedding 'nomic-embed-text' (obrigatório para busca vetorial) não está instalado.${NC}"
    read -p "Deseja realizar o download dele agora? (~270MB) (s/n): " pull_embed
    if [ "$pull_embed" = "s" ] || [ "$pull_embed" = "S" ]; then
        echo -e "${BLUE}Baixando nomic-embed-text...${NC}"
        curl -d '{"name": "nomic-embed-text"}' "$OLLAMA_HOST/api/pull"
        echo -e "\n${GREEN}[OK] Download concluído!${NC}"
    else
        echo -e "${RED}[AVISO] O sistema pode falhar na indexação se o modelo de embedding não for instalado posteriormente.${NC}"
    fi
fi

# 5.2 Inference Model
if echo "$MODELOS_INSTALADOS" | grep -q "$MODELO_SUGERIDO"; then
    echo -e "${GREEN}[OK] Modelo lógico sugerido '$MODELO_SUGERIDO' já está instalado.${NC}"
    MODELO_IA_ATIVO="$MODELO_SUGERIDO"
else
    echo -e "\n${YELLOW}O modelo lógico sugerido para o seu hardware é o '${MODELO_SUGERIDO}'.${NC}"
    read -p "Deseja realizar o download dele agora? (s/n): " pull_logic
    
    if [ "$pull_logic" = "s" ] || [ "$pull_logic" = "S" ]; then
        echo -e "${BLUE}Baixando $MODELO_SUGERIDO...${NC}"
        curl -d "{\"name\": \"$MODELO_SUGERIDO\"}" "$OLLAMA_HOST/api/pull"
        echo -e "\n${GREEN}[OK] Download concluído!${NC}"
        MODELO_IA_ATIVO="$MODELO_SUGERIDO"
    else
        read -p "Gostaria de informar o nome de outro modelo já instalado em seu PC para usar como padrão? (s/n): " usar_outro
        if [ "$usar_outro" = "s" ] || [ "$usar_outro" = "S" ]; then
            echo -e "Modelos locais disponíveis:"
            echo "$MODELOS_INSTALADOS" | sed 's/^/  - /'
            read -p "Digite o nome exato do modelo: " modelo_usuario
            if [ -n "$modelo_usuario" ]; then
                MODELO_IA_ATIVO="$modelo_usuario"
                echo -e "${GREEN}[OK] Modelo padrão definido para: $MODELO_IA_ATIVO${NC}"
            fi
        else
            echo -e "${RED}[AVISO] Lembre-se de definir o modelo correto no menu ou no arquivo config.conf antes de rodar o chat.${NC}"
        fi
    fi
fi

echo ""
read -p "Pressione [Enter] para concluir a configuração final..."

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
echo -e " 1. Coloque seus documentos jurídicos dentro da pasta correspondente em ${BLUE}./docs/${NC}"
echo -e " 2. Inicie a aplicação executando: ${GREEN_BOLD}./jus.sh${NC}"
echo -e "${GREEN_BOLD}=========================================================================${NC}"

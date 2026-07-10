#!/bin/bash
# =========================================================================
# AI-RAGJus Setup / Provisioning Script
# =========================================================================
set -eo pipefail

# Configurações de Cores para Terminal
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem Cor

# Detecção de execução externa (ex: curl -sSL ... | bash)
# Se não encontrar o arquivo jus.sh no diretório corrente, assume-se execução via curl
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

echo -e "${GREEN}=========================================================================${NC}"
echo -e "${GREEN}                   INICIANDO SETUP DO AI-RAGJUS                         ${NC}"
echo -e "${GREEN}=========================================================================${NC}"

# 1. Verificação de Hardware (RAM)
echo -e "\n${BLUE}[1/5] Verificando recursos do sistema...${NC}"
OS_TYPE="$(uname -s)"
RAM_GB=0

if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS
    RAM_BYTES=$(sysctl -n hw.memsize || echo 0)
    RAM_GB=$((RAM_BYTES / 1024 / 1024 / 1024))
elif [ "$OS_TYPE" = "Linux" ]; then
    # Linux / WSL2
    if [ -f /proc/meminfo ]; then
        RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        RAM_GB=$((RAM_KB / 1024 / 1024))
    fi
fi

echo "Memória RAM detectada: ${RAM_GB} GB"
if [ "$RAM_GB" -lt 4 ]; then
    echo -e "${RED}[AVISO] Seu sistema possui menos de 4GB de RAM (${RAM_GB}GB).${NC}"
    echo -e "${RED}É altamente recomendado utilizar modelos ultraleves (ex: qwen2.5:1.5b ou phi3).${NC}"
elif [ "$RAM_GB" -lt 8 ]; then
    echo -e "${YELLOW}[AVISO] Seu sistema possui menos de 8GB de RAM (${RAM_GB}GB).${NC}"
    echo -e "${YELLOW}Modelos de 7B/8B podem rodar de forma lenta ou causar lentidão no sistema.${NC}"
else
    echo -e "${GREEN}[OK] Recursos de memória RAM adequados.${NC}"
fi

# 2. Verificação de Dependências Básicas
echo -e "\n${BLUE}[2/5] Verificando ferramentas de linha de comando...${NC}"
DEPENDENCIES=("curl" "jq" "sqlite3" "pdftotext" "pandoc")
MISSING_DEPS=()

for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
        MISSING_DEPS+=("$dep")
    fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo -e "${YELLOW}[AVISO] As seguintes ferramentas estão ausentes: ${MISSING_DEPS[*]}${NC}"
    echo -e "Por favor, instale-as para o correto funcionamento do RAG:"
    if [ "$OS_TYPE" = "Darwin" ]; then
        echo -e "  -> No macOS (usando Homebrew):"
        echo -e "     ${GREEN}brew install poppler pandoc jq sqlite3${NC}"
    else
        echo -e "  -> No Linux/WSL (Debian/Ubuntu):"
        echo -e "     ${GREEN}sudo apt-get update && sudo apt-get install -y poppler-utils pandoc jq sqlite3${NC}"
    fi
else
    echo -e "${GREEN}[OK] Todas as ferramentas CLI básicas estão instaladas.${NC}"
fi

# 3. Verificação do Ollama
echo -e "\n${BLUE}[3/5] Verificando o serviço do Ollama...${NC}"
OLLAMA_HOST="http://localhost:11434"

if ! curl -s --connect-timeout 2 "$OLLAMA_HOST" &> /dev/null; then
    echo -e "${RED}[ERRO] Não foi possível conectar ao Ollama em $OLLAMA_HOST.${NC}"
    echo -e "Certifique-se de que o Ollama está instalado e rodando em segundo plano."
    echo -e "Faça o download em: https://ollama.com"
    exit 1
else
    echo -e "${GREEN}[OK] Serviço do Ollama detectado e ativo.${NC}"
fi

# 4. Verificação/Download dos Modelos do Ollama
echo -e "\n${BLUE}[4/5] Verificando modelos locais...${NC}"
MODELOS_INSTALADOS=$(curl -s "$OLLAMA_HOST/api/tags" | jq -r '.models[].name' 2>/dev/null || echo "")

verificar_e_baixar_modelo() {
    local modelo="$1"
    # Checa correspondência exata ou parcial (com/sem tag)
    if echo "$MODELOS_INSTALADOS" | grep -q "$modelo"; then
        echo -e "${GREEN}[OK] Modelo '$modelo' já está instalado.${NC}"
    else
        echo -e "${YELLOW}[INFO] Modelo '$modelo' não encontrado. Iniciando o download...${NC}"
        echo -e "Isso pode levar alguns minutos dependendo da sua conexão."
        curl -d "{\"name\": \"$modelo\"}" "$OLLAMA_HOST/api/pull"
        echo -e "\n${GREEN}[OK] Modelo '$modelo' baixado com sucesso.${NC}"
    fi
}

# Modelos padrão
verificar_e_baixar_modelo "nomic-embed-text"

if [ "$RAM_GB" -lt 8 ]; then
    echo -e "${YELLOW}[INFO] Como seu sistema possui recursos limitados, sugerimos um modelo menor.${NC}"
    MODELO_SUGERIDO="qwen2.5:1.5b"
else
    MODELO_SUGERIDO="qwen2.5:7b"
fi
verificar_e_baixar_modelo "$MODELO_SUGERIDO"

# 5. Criação das Pastas Padrão e Configuração
echo -e "\n${BLUE}[5/5] Organizando a estrutura de diretórios e arquivos de configuração...${NC}"
mkdir -p docs/leis docs/processos docs/contratos
mkdir -p .cache_vetorial
mkdir -p src

echo -e "${GREEN}[OK] Pastas padrão criadas.${NC}"

if [ ! -f "config.conf" ]; then
    cp config.conf.example config.conf
    # Ajusta o modelo sugerido no config.conf se necessário
    if [ "$MODELO_SUGERIDO" != "qwen2.5:7b" ]; then
        sed -i.bak "s/MODELO_IA=\"qwen2.5:7b\"/MODELO_IA=\"$MODELO_SUGERIDO\"/" config.conf && rm -f config.conf.bak
    fi
    echo -e "${GREEN}[OK] Arquivo config.conf inicializado a partir do exemplo.${NC}"
else
    echo -e "${YELLOW}[INFO] O arquivo config.conf já existe. Nenhuma alteração foi feita nele.${NC}"
fi

echo -e "\n${GREEN}=========================================================================${NC}"
echo -e "${GREEN}             SETUP CONCLUÍDO COM SUCESSO PARA AI-JUSRAG!                 ${NC}"
echo -e "${GREEN}=========================================================================${NC}"
echo -e "Você já pode colocar seus arquivos (.pdf, .docx, .txt, etc.) na pasta correspondente em ${BLUE}./docs/${NC}"
echo -e "e iniciar a aplicação rodando: ${GREEN}./jus.sh${NC}"
echo -e "${GREEN}=========================================================================${NC}"

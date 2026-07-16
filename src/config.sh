#!/bin/bash
# =========================================================================
# AI-JusRAG - Módulo de Gerenciamento de Configuração
# =========================================================================

# Detecta modo não-interativo (usado pela interface Web/Flask) para suprimir
# cores ANSI e prompts que leem de /dev/tty (ver src/ai.sh). Mantém o padrão
# "0" para preservar o comportamento interativo do jus.sh/CLI.
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
export NON_INTERACTIVE

# Carrega as configurações do arquivo config.conf ou define padrões caso não exista
carregar_configuracoes() {
    local app_dir="$1"
    local config_file="$app_dir/config.conf"
    
    # Valores padrão iniciais (caso o arquivo não exista)
    PASTA_ALVO="./docs"
    CACHE_DIR="./.cache_vetorial"
    OLLAMA_URL="http://localhost:11434"
    OLLAMA_URL_EMBEDDING="http://localhost:11435"
    MODELO_IA="qwen2.5:7b"
    MODELO_EMBEDDING="nomic-embed-text"
    MAX_FILE_SIZE_MB=50
    CHUNK_SIZE=1000
    CHUNK_OVERLAP=200
    TEMPERATURA=0
    CONTEXT_WINDOW=16384
    RAGSEC_MODE=0
    AUDIT_RETENTION_DIAS=365

    if [ -f "$config_file" ]; then
        # Lê linha a linha para carregar apenas variáveis bem formatadas e evitar execução de código arbitrário
        while IFS='=' read -r key value || [ -n "$key" ]; do
            # Ignora linhas vazias ou comentários
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${key//[[:space:]]/}" ]] && continue
            
            # Limpa espaços em branco e aspas das variáveis
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" | xargs)
            
            case "$key" in
                PASTA_ALVO) PASTA_ALVO="$value" ;;
                CACHE_DIR) CACHE_DIR="$value" ;;
                OLLAMA_URL) OLLAMA_URL="$value" ;;
                OLLAMA_URL_EMBEDDING) OLLAMA_URL_EMBEDDING="$value" ;;
                MODELO_IA) MODELO_IA="$value" ;;
                MODELO_EMBEDDING) MODELO_EMBEDDING="$value" ;;
                MAX_FILE_SIZE_MB) MAX_FILE_SIZE_MB="$value" ;;
                CHUNK_SIZE) CHUNK_SIZE="$value" ;;
                CHUNK_OVERLAP) CHUNK_OVERLAP="$value" ;;
                TEMPERATURA) TEMPERATURA="$value" ;;
                CONTEXT_WINDOW) CONTEXT_WINDOW="$value" ;;
                RAGSEC_MODE) RAGSEC_MODE="$value" ;;
                AUDIT_RETENTION_DIAS) AUDIT_RETENTION_DIAS="$value" ;;
            esac
        done < "$config_file"
    fi

    # Exporta para os outros scripts
    export PASTA_ALVO CACHE_DIR OLLAMA_URL OLLAMA_URL_EMBEDDING MODELO_IA MODELO_EMBEDDING MAX_FILE_SIZE_MB CHUNK_SIZE CHUNK_OVERLAP TEMPERATURA CONTEXT_WINDOW RAGSEC_MODE AUDIT_RETENTION_DIAS
}

# Atualiza uma chave de configuração no config.conf
atualizar_configuracao() {
    local chave="$1"
    local valor="$2"
    local app_dir="$3"
    local config_file="$app_dir/config.conf"

    if [ ! -f "$config_file" ]; then
        echo "# AI-JusRAG Configuration File" > "$config_file"
    fi

    # Atualiza a variável na memória atual para uso imediato do script
    case "$chave" in
        PASTA_ALVO) PASTA_ALVO="$valor" ;;
        CACHE_DIR) CACHE_DIR="$valor" ;;
        OLLAMA_URL) OLLAMA_URL="$valor" ;;
        OLLAMA_URL_EMBEDDING) OLLAMA_URL_EMBEDDING="$valor" ;;
        MODELO_IA) MODELO_IA="$valor" ;;
        MODELO_EMBEDDING) MODELO_EMBEDDING="$valor" ;;
        MAX_FILE_SIZE_MB) MAX_FILE_SIZE_MB="$valor" ;;
        CHUNK_SIZE) CHUNK_SIZE="$valor" ;;
        CHUNK_OVERLAP) CHUNK_OVERLAP="$valor" ;;
        TEMPERATURA) TEMPERATURA="$valor" ;;
        CONTEXT_WINDOW) CONTEXT_WINDOW="$valor" ;;
        RAGSEC_MODE) RAGSEC_MODE="$valor" ;;
        AUDIT_RETENTION_DIAS) AUDIT_RETENTION_DIAS="$valor" ;;
    esac

    # Atualiza ou adiciona a linha no arquivo
    if grep -q "^$chave=" "$config_file"; then
        # Modifica em plataformas Linux e macOS de forma compatível
        if [ "$(uname -s)" = "Darwin" ]; then
            sed -i '' "s|^$chave=.*|$chave=\"$valor\"|" "$config_file"
        else
            sed -i "s|^$chave=.*|$chave=\"$valor\"|" "$config_file"
        fi
    else
        echo "$chave=\"$valor\"" >> "$config_file"
    fi
}

#!/bin/bash
# =========================================================================
# AI-JusRAG - Módulo de Gerenciamento de Configuração
# =========================================================================

# Detecta modo não-interativo (usado pela interface Web/Flask) para suprimir
# cores ANSI e prompts que leem de /dev/tty (ver src/ai.sh). Mantém o padrão
# "0" para preservar o comportamento interativo do jus.sh/CLI.
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
export NON_INTERACTIVE

# Mapa de janelas de contexto nativas conhecidas por modelo. Consultado por
# detect_model_context() (definida em src/ai.sh) quando CONTEXT_WINDOW="auto"
# no config.conf, para preencher num_ctx sem exigir que o usuário descubra e
# digite o valor manualmente. Modelos ausentes daqui caem no fallback de 8192
# tokens (conservador) dentro da própria detect_model_context().
declare -A MODELO_CONTEXT_MAP=(
    ["lfm2.5:8b"]=125000
    ["lfm2.5:1.5b"]=125000
    ["qwen2.5:1.5b"]=32768
    ["llama2"]=4096
)

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
    CONTEXT_WINDOW="auto"
    RAGSEC_MODE=0
    AUDIT_RETENTION_DIAS=365
    PROMPT_CLARIFICATION=1

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
                PROMPT_CLARIFICATION) PROMPT_CLARIFICATION="$value" ;;
            esac
        done < "$config_file"
    fi

    # Resolve CONTEXT_WINDOW="auto" para um valor numérico com base em
    # MODELO_IA, usando detect_model_context() (src/ai.sh) + MODELO_CONTEXT_MAP
    # acima. Roda uma única vez aqui, no load da config; se CONTEXT_WINDOW já
    # vier com um número explícito no config.conf, é apenas repassado adiante.
    local _context_window_configurado="$CONTEXT_WINDOW"
    CONTEXT_WINDOW=$(detect_model_context "$MODELO_IA" "$CONTEXT_WINDOW")
    if [ "$NON_INTERACTIVE" != "1" ]; then
        echo "[DEBUG] Janela de contexto (CONTEXT_WINDOW): modelo='$MODELO_IA' configurado='$_context_window_configurado' -> resolvido=$CONTEXT_WINDOW" >&2
    fi

    # Exporta para os outros scripts
    export PASTA_ALVO CACHE_DIR OLLAMA_URL OLLAMA_URL_EMBEDDING MODELO_IA MODELO_EMBEDDING MAX_FILE_SIZE_MB CHUNK_SIZE CHUNK_OVERLAP TEMPERATURA CONTEXT_WINDOW RAGSEC_MODE AUDIT_RETENTION_DIAS PROMPT_CLARIFICATION
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
        PROMPT_CLARIFICATION) PROMPT_CLARIFICATION="$valor" ;;
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

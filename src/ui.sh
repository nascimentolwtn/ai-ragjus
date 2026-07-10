#!/bin/bash
# =========================================================================
# AI-JusRAG - Módulo de Visualização & Interface CLI (Tela Verde)
# =========================================================================

# Definições de cores ANSI (Estilo Tela Verde Clássico)
GREEN='\033[0;32m'
GREEN_BOLD='\033[1;32m'
GREEN_DIM='\033[2;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # Sem Cor (Reset)

# Limpa a tela de forma estilizada
limpar_tela_retro() {
    # Tenta usar tput para limpar, caso contrário usa escape code
    if command -v tput &> /dev/null; then
        tput clear
    else
        echo -ne "\033[H\033[2J"
    fi
}

# Desenha o cabeçalho clássico do sistema
exibir_cabecalho() {
    echo -e "${GREEN_BOLD}=========================================================================${NC}"
    echo -e "${GREEN_BOLD}                   A I  -  J U S R A G   v0.1.0                          ${NC}"
    echo -e "${GREEN_DIM}         [ SISTEMA DE BUSCA JURÍDICA LOCAL - 100% OFF-LINE ]            ${NC}"
    echo -e "${GREEN_BOLD}=========================================================================${NC}"
    echo -e "${GREEN_DIM} Status do Ollama: ${GREEN}ATIVO${GREEN_DIM} | Privacidade: ${GREEN}MÁXIMA (LOCAL/AIR-GAPPED)${NC}"
    echo -e "${GREEN_BOLD}=========================================================================${NC}"
    echo ""
}

# Simula o efeito de digitação clássico de terminais retrô
exibir_texto_digitando() {
    local texto="$1"
    local delay=0.015 # Tempo de delay entre caracteres em segundos

    # Loop caractere por caractere
    for (( i=0; i<${#texto}; i++ )); do
        echo -ne "${GREEN}${texto:$i:1}${NC}"
        # Compatibilidade com sleeps menores que 1 segundo
        sleep "$delay"
    done
    echo ""
}

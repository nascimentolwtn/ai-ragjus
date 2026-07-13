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

# Desenha o cabeçalho clássico do sistema (rebrandeado para RAGSEC quando ativo)
exibir_cabecalho() {
    if [ "${RAGSEC_MODE:-0}" = "1" ]; then
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo -e "${GREEN_BOLD}          R A G S E C   —   C O M P A N Y   S E C R E T   R A G          ${NC}"
        echo -e "${GREEN_DIM}   [ RBAC + CLASSIFICAÇÃO + DLP + AUDITORIA - 100% OFF-LINE / AIR-GAPPED ]${NC}"
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        if [ -n "${RAGSEC_USER:-}" ]; then
            echo -e "${GREEN_DIM} Usuário: ${GREEN}$RAGSEC_USER${GREEN_DIM} | Papel: ${GREEN}$RAGSEC_ROLE${GREEN_DIM} | Clearance: ${GREEN}$RAGSEC_CLEARANCE${NC}"
        else
            echo -e "${YELLOW} Nenhuma sessão ativa. É necessário fazer login para continuar.${NC}"
        fi
        echo -e "${GREEN_BOLD}=========================================================================${NC}"
        echo ""
        return
    fi

    echo -e "${GREEN_BOLD}=========================================================================${NC}"
    echo -e "${GREEN_BOLD}                   A I  -  J U S R A G   v0.1.0                          ${NC}"
    echo -e "${GREEN_DIM}         [ SISTEMA DE BUSCA JURÍDICA LOCAL - 100% OFF-LINE ]            ${NC}"
    echo -e "${GREEN_BOLD}=========================================================================${NC}"
    echo -e "${GREEN_DIM} Status do Ollama: ${GREEN}ATIVO${GREEN_DIM} | Privacidade: ${GREEN}MÁXIMA (LOCAL/AIR-GAPPED)${NC}"
    echo -e "${GREEN_BOLD}=========================================================================${NC}"
    echo ""
}

# Exibe as opções de menu adicionais do RAGSEC, visíveis conforme o papel logado.
# Puramente cosmético: o gate real de autorização acontece em jus.sh (server-side).
exibir_menu_ragsec_extra() {
    [ "${RAGSEC_MODE:-0}" = "1" ] || return 0

    echo -e ""
    if [ -n "${RAGSEC_USER:-}" ]; then
        echo -e "  ${GREEN}L)${NC} Logout (usuário atual: ${BLUE}$RAGSEC_USER${NC} / ${BLUE}$RAGSEC_ROLE${NC})"
    else
        echo -e "  ${GREEN}L)${NC} Login"
    fi

    if [ "${RAGSEC_ROLE:-}" = "exec" ]; then
        echo -e "  ${GREEN}U)${NC} [Admin] Gerenciamento de Usuários"
        echo -e "  ${GREEN}D)${NC} [Admin] Regras de DLP"
    fi
    if [ "${RAGSEC_ROLE:-}" = "exec" ] || [ "${RAGSEC_ROLE:-}" = "manager" ]; then
        echo -e "  ${GREEN}C)${NC} [Admin] Gerenciador de Classificação de Documentos"
    fi
    if [ "${RAGSEC_ROLE:-}" = "auditor" ]; then
        echo -e "  ${GREEN}A)${NC} [Auditor] Ver Log de Auditoria"
    fi
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

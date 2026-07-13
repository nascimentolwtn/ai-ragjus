#!/bin/bash
# =========================================================================
# RAGSEC - Módulo RBAC (Controle de Acesso Baseado em Papel)
# =========================================================================
# Só é sourceado por jus.sh quando RAGSEC_MODE=1 (ver detecção em jus.sh).

# Retorna o nível numérico de uma classificação de documento/chunk
# public=0 < internal=1 < confidential=2 < secret=3
obter_nivel_classificacao() {
    local classificacao="$1"
    case "$classificacao" in
        public) echo 0 ;;
        internal) echo 1 ;;
        confidential) echo 2 ;;
        secret) echo 3 ;;
        *) echo 1 ;; # fallback conservador: trata como 'internal'
    esac
}

# Retorna o clearance numérico associado a um papel (role)
obter_clearance_papel() {
    local role="$1"
    case "$role" in
        engineer) echo 1 ;;
        manager) echo 2 ;;
        exec) echo 3 ;;
        auditor) echo 0 ;;
        *) echo 0 ;;
    esac
}

# Monta a cláusula SQL (sem o prefixo WHERE) que restringe as classificações
# visíveis para o clearance/papel atual. Usada por buscar_trechos_relevantes()
# para injetar o filtro de acesso server-side (nunca fornecido pelo usuário).
#
# Uso: filtro_clearance_sql "$RAGSEC_CLEARANCE"
filtro_clearance_sql() {
    local clearance="${1:-${RAGSEC_CLEARANCE:-0}}"
    local role="${RAGSEC_ROLE:-}"

    # O papel 'auditor' nunca consulta conteúdo (somente o log de auditoria),
    # independentemente do clearance numérico - trata-se como negação total.
    if [ "$role" = "auditor" ]; then
        echo "classificacao IN ('__ragsec_sem_acesso__')"
        return 0
    fi

    local niveis=()
    [ "$clearance" -ge 0 ] 2>/dev/null && niveis+=("'public'")
    [ "$clearance" -ge 1 ] 2>/dev/null && niveis+=("'internal'")
    [ "$clearance" -ge 2 ] 2>/dev/null && niveis+=("'confidential'")
    [ "$clearance" -ge 3 ] 2>/dev/null && niveis+=("'secret'")

    if [ ${#niveis[@]} -eq 0 ]; then
        echo "classificacao IN ('__ragsec_sem_acesso__')"
    else
        local lista
        lista=$(IFS=,; echo "${niveis[*]}")
        echo "classificacao IN ($lista)"
    fi
}

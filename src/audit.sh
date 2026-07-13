#!/bin/bash
# =========================================================================
# RAGSEC - Módulo de Auditoria (audit_log)
# =========================================================================
# Só é sourceado por jus.sh quando RAGSEC_MODE=1 (ver detecção em jus.sh).
# O log é append-only na prática: não há caminho de UI que atualize ou
# apague linhas individuais; apenas purgar_auditoria() remove por retenção.

# Grava uma linha em audit_log para o turno de chat atual.
# Args: username role query_text docs_acessados_json max_score dlp_action dlp_rule
registrar_auditoria() {
    local username="$1"
    local role="$2"
    local query_text="$3"
    local docs_acessados_json="${4:-[]}"
    local max_score="${5:-0}"
    local dlp_action="${6:-allow}"
    local dlp_rule="${7:-}"

    local db_path
    db_path=$(obter_db_path)
    [ -f "$db_path" ] || return 0

    local u r q d rule
    u=$(_ragsec_escapar_sql "$username")
    r=$(_ragsec_escapar_sql "$role")
    q=$(_ragsec_escapar_sql "$query_text")
    d=$(_ragsec_escapar_sql "$docs_acessados_json")
    rule=$(_ragsec_escapar_sql "$dlp_rule")

    # max_score deve ser numérico; cai para 0 se vazio/():
    if ! [[ "$max_score" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then
        max_score=0
    fi

    sqlite3 "$db_path" "INSERT INTO audit_log (username, role, query_text, docs_acessados, max_score, dlp_action, dlp_rule) VALUES ('$u', '$r', '$q', '$d', $max_score, '${dlp_action:-allow}', '$rule');" 2>/dev/null

    chmod 600 "$db_path" 2>/dev/null || true
}

# Remove entradas de audit_log mais antigas que AUDIT_RETENTION_DIAS (padrão 365).
purgar_auditoria() {
    local db_path
    db_path=$(obter_db_path)
    local dias="${AUDIT_RETENTION_DIAS:-365}"

    [ -f "$db_path" ] || return 0

    if ! [[ "$dias" =~ ^[0-9]+$ ]]; then
        dias=365
    fi

    sqlite3 "$db_path" "DELETE FROM audit_log WHERE ts < datetime('now', '-$dias days');" 2>/dev/null
    echo -e "${GREEN}[OK] Registros de auditoria com mais de $dias dias foram removidos.${NC}"
}

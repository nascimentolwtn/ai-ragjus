#!/bin/bash
# =========================================================================
# RAGSEC - Módulo de DLP (Data Loss Prevention) Pós-Geração
# =========================================================================
# Só é sourceado por jus.sh quando RAGSEC_MODE=1 (ver detecção em jus.sh).
#
# Defesa em profundidade: o filtro de clearance em buscar_trechos_relevantes()
# já impede que chunks acima da classificação do usuário entrem no contexto do
# prompt (pré-retrieval). Este módulo faz a segunda passada: varre a resposta
# JÁ GERADA pelo modelo antes de exibi-la, procurando padrões de vazamento
# (chaves, JWTs, connection strings, hosts internos, etc.) definidos em
# dlp_rules. `block` suprime a resposta inteira; `redact` substitui os
# trechos por [REDACTED]. Toda decisão é auditável via audit_log.

# Após uma chamada, populam-se as variáveis globais:
#   DLP_ACAO           allow | redact | block
#   DLP_REGRA          id(s) da(s) regra(s) que dispararam (vazio se allow)
#   DLP_RESPOSTA_FINAL texto a ser exibido ao usuário
executar_dlp_pos_geracao() {
    local resposta="$1"
    local db_path
    db_path=$(obter_db_path)

    DLP_ACAO="allow"
    DLP_REGRA=""
    DLP_RESPOSTA_FINAL="$resposta"

    [ -f "$db_path" ] || return 0

    # 1ª passada: regras de bloqueio têm prioridade absoluta sobre redação.
    local regras_block
    regras_block=$(sqlite3 -separator '|' "$db_path" \
        "SELECT id, padrao FROM dlp_rules WHERE ativo = 1 AND acao = 'block';" 2>/dev/null || echo "")

    if [ -n "$regras_block" ]; then
        while IFS='|' read -r regra_id padrao || [ -n "$regra_id" ]; do
            [ -z "$regra_id" ] && continue
            if printf '%s' "$resposta" | grep -qP "$padrao" 2>/dev/null; then
                DLP_ACAO="block"
                DLP_REGRA="$regra_id"
                DLP_RESPOSTA_FINAL=$(block_response)
                return 0
            fi
        done <<< "$regras_block"
    fi

    # 2ª passada: regras de redação (podem se acumular sobre a mesma resposta).
    local regras_redact
    regras_redact=$(sqlite3 -separator '|' "$db_path" \
        "SELECT id, padrao FROM dlp_rules WHERE ativo = 1 AND acao = 'redact';" 2>/dev/null || echo "")

    if [ -n "$regras_redact" ]; then
        while IFS='|' read -r regra_id padrao || [ -n "$regra_id" ]; do
            [ -z "$regra_id" ] && continue
            if printf '%s' "$DLP_RESPOSTA_FINAL" | grep -qP "$padrao" 2>/dev/null; then
                DLP_ACAO="redact"
                DLP_REGRA="${DLP_REGRA:+$DLP_REGRA,}$regra_id"
                DLP_RESPOSTA_FINAL=$(redact_matches "$DLP_RESPOSTA_FINAL" "$padrao")
            fi
        done <<< "$regras_redact"
    fi

    return 0
}

# Substitui todas as ocorrências do regex (PCRE) $2 no texto $1 por [REDACTED].
# O padrão é repassado via variável de ambiente para o perl (evita problemas
# de quoting/delimitador ao interpolar regex arbitrário numa string de shell).
redact_matches() {
    local texto="$1"
    local padrao="$2"

    if command -v perl &> /dev/null; then
        PADRAO_DLP="$padrao" perl -pe 'BEGIN { $p = $ENV{PADRAO_DLP} } s/$p/[REDACTED]/g' <<< "$texto" 2>/dev/null || echo "$texto"
    else
        # Sem perl disponível, não arrisca uma substituição incorreta - mantém o texto.
        echo "$texto" >&2
        echo "$texto"
    fi
}

# Mensagem retornada no lugar da resposta quando uma regra 'block' dispara.
block_response() {
    echo "[RAGSEC] Esta resposta foi bloqueada pelo motor de DLP por conter informação potencialmente sensível ou não autorizada. Se você acredita que isso é um erro, contate o administrador de segurança."
}

# Popula a tabela dlp_rules com as regras padrão na primeira execução (idempotente).
_ragsec_seed_dlp_rules() {
    local db_path
    db_path=$(obter_db_path)
    [ -f "$db_path" ] || return 0

    local total
    total=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM dlp_rules;" 2>/dev/null || echo "0")
    [ "${total:-0}" -gt 0 ] && return 0

    sqlite3 "$db_path" <<'EOF'
INSERT INTO dlp_rules (id, padrao, acao, escopo, ativo) VALUES
    ('secret_key', '(AKIA[0-9A-Z]{16})|((?i)api[_-]?key\s*[:=]\s*\S+)', 'redact', 'all', 1),
    ('priv_key', '-----BEGIN (RSA|EC|OPENSSH) PRIVATE KEY-----', 'block', 'all', 1),
    ('jwt', 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', 'redact', 'all', 1),
    ('conn_string', '(postgres|mysql|mongodb)://[^ ]+:[^ @]+@', 'redact', 'all', 1),
    ('internal_host', '(?i)\b\w+\.internal\.corp\b', 'redact', 'all', 1),
    ('roadmap_leak', '(?i)(acquisition|layoff|unreleased)', 'block', 'all', 1);
EOF
    echo -e "${GREEN}[OK] Regras DLP padrão semeadas.${NC}" >&2
}

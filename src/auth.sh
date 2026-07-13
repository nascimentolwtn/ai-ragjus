#!/bin/bash
# =========================================================================
# RAGSEC - Módulo de Autenticação e Sessão (RBAC)
# =========================================================================
# Só é sourceado por jus.sh quando RAGSEC_MODE=1 (ver detecção em jus.sh).
# Identidade local (air-gapped, sem IdP de rede): tabela `usuarios` com hash
# salgado via `openssl passwd -6`. Sessão materializada em arquivo mode 600.

# Escapa aspas simples para uso seguro em literais SQL
_ragsec_escapar_sql() {
    echo "$1" | sed "s/'/''/g"
}

# Calcula o hash SHA-512-crypt de uma senha, opcionalmente reusando um salt existente
_ragsec_hash_senha() {
    local senha="$1"
    local salt="$2"
    if [ -n "$salt" ]; then
        openssl passwd -6 -salt "$salt" "$senha" 2>/dev/null
    else
        openssl passwd -6 "$senha" 2>/dev/null
    fi
}

# Verifica uma senha em texto puro contra um hash armazenado ($6$salt$hash)
_ragsec_verificar_senha() {
    local senha="$1"
    local hash_armazenado="$2"
    local salt
    salt=$(echo "$hash_armazenado" | awk -F'$' '{print $3}')
    local hash_calculado
    hash_calculado=$(_ragsec_hash_senha "$senha" "$salt")
    [ -n "$hash_calculado" ] && [ "$hash_calculado" = "$hash_armazenado" ]
}

# Cria o usuário inicial (papel exec) quando a tabela `usuarios` está vazia.
# Sem usuários default de fábrica - o primeiro login sempre cria o admin.
_ragsec_criar_usuario_inicial() {
    local db_path="$1"

    echo -e "${YELLOW}[RAGSEC] Nenhum usuário cadastrado. Criando o primeiro administrador (papel: exec).${NC}"
    local usuario senha senha2
    read -p "Novo usuário administrador: " usuario < /dev/tty
    read -s -p "Senha: " senha < /dev/tty
    echo ""
    read -s -p "Confirme a senha: " senha2 < /dev/tty
    echo ""

    if [ -z "$usuario" ] || [ -z "$senha" ] || [ "$senha" != "$senha2" ]; then
        echo -e "${RED}[ERRO] Usuário/senha inválidos ou senhas não conferem. Tente novamente.${NC}" >&2
        return 1
    fi

    local hash_senha
    hash_senha=$(_ragsec_hash_senha "$senha")
    if [ -z "$hash_senha" ]; then
        echo -e "${RED}[ERRO] Falha ao gerar hash de senha (openssl indisponível?).${NC}" >&2
        return 1
    fi

    local usuario_esc hash_esc
    usuario_esc=$(_ragsec_escapar_sql "$usuario")
    hash_esc=$(_ragsec_escapar_sql "$hash_senha")

    sqlite3 "$db_path" "INSERT INTO usuarios (username, senha_hash, role, clearance) VALUES ('$usuario_esc', '$hash_esc', 'exec', 3);" 2>/dev/null

    echo -e "${GREEN}[OK] Administrador '$usuario' criado com papel 'exec'.${NC}"
    return 0
}

# Cria/renova o arquivo de sessão (mode 600) sob $CACHE_DIR/.session
_ragsec_criar_sessao() {
    local usuario="$1" role="$2" clearance="$3"
    mkdir -p "$CACHE_DIR"
    local sessao_file="$CACHE_DIR/.session"
    local token
    token=$(openssl rand -hex 16 2>/dev/null || echo "$RANDOM$RANDOM$(date +%s)")

    printf '%s|%s|%s|%s|%s\n' "$usuario" "$role" "$clearance" "$token" "$(date +%s)" > "$sessao_file"
    chmod 600 "$sessao_file" 2>/dev/null || true
}

# Prompt interativo de login. Em sucesso, define/exporta RAGSEC_USER, RAGSEC_ROLE,
# RAGSEC_CLEARANCE e materializa o arquivo de sessão. Retorna 1 em falha.
login_usuario() {
    local db_path
    db_path=$(obter_db_path)
    mkdir -p "$CACHE_DIR"
    inicializar_banco_vetorial

    local total_usuarios
    total_usuarios=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM usuarios;" 2>/dev/null || echo "0")
    if [ "${total_usuarios:-0}" -eq 0 ]; then
        _ragsec_criar_usuario_inicial "$db_path" || return 1
    fi

    local tentativas=0
    while [ "$tentativas" -lt 3 ]; do
        local usuario senha
        read -p "Usuário: " usuario < /dev/tty
        read -s -p "Senha: " senha < /dev/tty
        echo ""

        local usuario_esc registro
        usuario_esc=$(_ragsec_escapar_sql "$usuario")
        registro=$(sqlite3 -separator '|' "$db_path" \
            "SELECT senha_hash, role, clearance, ativo FROM usuarios WHERE username = '$usuario_esc';" 2>/dev/null || echo "")

        if [ -z "$registro" ]; then
            echo -e "${RED}[ERRO] Usuário ou senha inválidos.${NC}" >&2
            tentativas=$((tentativas + 1))
            continue
        fi

        local hash_armazenado role clearance ativo
        IFS='|' read -r hash_armazenado role clearance ativo <<< "$registro"

        if [ "$ativo" != "1" ]; then
            echo -e "${RED}[ERRO] Usuário desativado. Contate o administrador.${NC}" >&2
            return 1
        fi

        if _ragsec_verificar_senha "$senha" "$hash_armazenado"; then
            RAGSEC_USER="$usuario"
            RAGSEC_ROLE="$role"
            RAGSEC_CLEARANCE="$clearance"
            export RAGSEC_USER RAGSEC_ROLE RAGSEC_CLEARANCE

            _ragsec_criar_sessao "$usuario" "$role" "$clearance"
            echo -e "${GREEN}[OK] Login bem-sucedido. Bem-vindo(a), $usuario ($role).${NC}"
            return 0
        fi

        echo -e "${RED}[ERRO] Usuário ou senha inválidos.${NC}" >&2
        tentativas=$((tentativas + 1))
    done

    echo -e "${RED}[ERRO] Número máximo de tentativas de login excedido.${NC}" >&2
    return 1
}

# Valida o arquivo de sessão atual: existência, permissões (600) e, em caso
# positivo, revalida papel/clearance/ativo contra a tabela `usuarios` (o
# arquivo de sessão é conveniência, não a fonte da verdade). Em sucesso,
# (re)exporta RAGSEC_USER/RAGSEC_ROLE/RAGSEC_CLEARANCE.
validar_sessao() {
    local sessao_file="$CACHE_DIR/.session"

    [ -f "$sessao_file" ] || return 1

    local perms
    perms=$(stat -c '%a' "$sessao_file" 2>/dev/null || stat -f '%Lp' "$sessao_file" 2>/dev/null || echo "")
    if [ "$perms" != "600" ]; then
        echo -e "${RED}[ERRO] Arquivo de sessão com permissões inseguras ($perms). Sessão invalidada.${NC}" >&2
        rm -f "$sessao_file"
        return 1
    fi

    local linha
    linha=$(cat "$sessao_file" 2>/dev/null || echo "")
    [ -n "$linha" ] || return 1

    local usuario role clearance token criado_em
    IFS='|' read -r usuario role clearance token criado_em <<< "$linha"
    [ -n "$usuario" ] && [ -n "$role" ] || return 1

    local db_path registro
    db_path=$(obter_db_path)
    [ -f "$db_path" ] || return 1

    local usuario_esc
    usuario_esc=$(_ragsec_escapar_sql "$usuario")
    registro=$(sqlite3 -separator '|' "$db_path" \
        "SELECT role, clearance, ativo FROM usuarios WHERE username = '$usuario_esc';" 2>/dev/null || echo "")

    if [ -z "$registro" ]; then
        rm -f "$sessao_file"
        return 1
    fi

    local role_atual clearance_atual ativo_atual
    IFS='|' read -r role_atual clearance_atual ativo_atual <<< "$registro"

    if [ "$ativo_atual" != "1" ]; then
        rm -f "$sessao_file"
        return 1
    fi

    RAGSEC_USER="$usuario"
    RAGSEC_ROLE="$role_atual"
    RAGSEC_CLEARANCE="$clearance_atual"
    export RAGSEC_USER RAGSEC_ROLE RAGSEC_CLEARANCE
    return 0
}

# Encerra a sessão atual: remove o arquivo de sessão e limpa as env vars.
logout_usuario() {
    local sessao_file="$CACHE_DIR/.session"
    rm -f "$sessao_file"
    unset RAGSEC_USER RAGSEC_ROLE RAGSEC_CLEARANCE
    echo -e "${GREEN}[OK] Sessão encerrada.${NC}"
}

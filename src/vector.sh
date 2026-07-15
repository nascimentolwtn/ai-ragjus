#!/bin/bash
# =========================================================================
# AI-RAGJus - Módulo de Banco de Dados Vetorial (SQLite + Busca de Cosseno)
# =========================================================================
#
# Teste manual do escopo de documentos (SCOPE_DOCS), a partir da raiz do repo:
#
#   # Baseline (sem escopo — comportamento atual)
#   NON_INTERACTIVE=1 bash src/rag_query.sh "uma pergunta qualquer" | jq '.sources | length' 2>/dev/null
#
#   # Escopo para um único documento (deve retornar apenas trechos desse arquivo)
#   DOC=$(sqlite3 .cache_vetorial/rag_store.db "SELECT DISTINCT caminho_arquivo FROM document_chunks LIMIT 1;")
#   SCOPE_DOCS=$(jq -cn --arg d "$DOC" '[$d]') NON_INTERACTIVE=1 bash src/rag_query.sh "pergunta" \
#     | jq -r 'select(.type=="sources") | .content[].caminho' | sort -u
#
#   # SCOPE_DOCS malformado → cai no acervo completo, sem crash
#   SCOPE_DOCS='invalid-json' NON_INTERACTIVE=1 bash src/rag_query.sh "pergunta"

# Retorna o caminho absoluto do banco de dados SQLite
obter_db_path() {
    echo "$CACHE_DIR/rag_store.db"
}

# Cria a tabela de chunks vetoriais caso não exista
inicializar_banco_vetorial() {
    local db_path
    db_path=$(obter_db_path)
    
    sqlite3 "$db_path" <<EOF
CREATE TABLE IF NOT EXISTS document_chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    caminho_arquivo TEXT NOT NULL,
    hash_arquivo TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    conteudo_texto TEXT NOT NULL,
    vetor_embedding TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_caminho ON document_chunks (caminho_arquivo);
CREATE INDEX IF NOT EXISTS idx_hash ON document_chunks (hash_arquivo);
EOF

    # Migrações RAGSEC (RBAC / Classificação / DLP / Auditoria).
    # Só executa quando RAGSEC_MODE=1 - a build jurídica padrão nunca toca nestas tabelas.
    if [ "${RAGSEC_MODE:-0}" = "1" ]; then
        _ragsec_migrar_schema "$db_path"
    fi
}

# Aplica migrações idempotentes de schema para o modo RAGSEC (RBAC/Classificação/DLP/Auditoria)
_ragsec_migrar_schema() {
    local db_path="$1"

    # ALTER TABLE ADD COLUMN não é idempotente no SQLite; verifica antes de aplicar.
    local coluna_existe
    coluna_existe=$(sqlite3 "$db_path" "PRAGMA table_info(document_chunks);" 2>/dev/null | awk -F'|' '{print $2}' | grep -c '^classificacao$' || true)
    if [ "${coluna_existe:-0}" -eq 0 ]; then
        sqlite3 "$db_path" "ALTER TABLE document_chunks ADD COLUMN classificacao TEXT NOT NULL DEFAULT 'internal';"
    fi

    sqlite3 "$db_path" <<'EOF'
CREATE INDEX IF NOT EXISTS idx_classificacao ON document_chunks (classificacao);

CREATE TABLE IF NOT EXISTS usuarios (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT UNIQUE NOT NULL,
    senha_hash    TEXT NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('engineer','manager','exec','auditor')),
    clearance     INTEGER NOT NULL,
    ativo         INTEGER NOT NULL DEFAULT 1,
    criado_em     TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Registro de classificação por documento (fonte da verdade por arquivo)
CREATE TABLE IF NOT EXISTS doc_classificacao (
    caminho_arquivo TEXT PRIMARY KEY,
    classificacao   TEXT NOT NULL CHECK (classificacao IN ('public','internal','confidential','secret')),
    nivel           INTEGER NOT NULL,
    classificado_por TEXT,
    classificado_em TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS audit_log (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    ts             TEXT NOT NULL DEFAULT (datetime('now')),
    username       TEXT NOT NULL,
    role           TEXT NOT NULL,
    query_text     TEXT NOT NULL,
    docs_acessados TEXT,
    max_score      REAL,
    dlp_action     TEXT NOT NULL,
    dlp_rule       TEXT
);

CREATE TABLE IF NOT EXISTS dlp_rules (
    id       TEXT PRIMARY KEY,
    padrao   TEXT NOT NULL,
    acao     TEXT NOT NULL,
    escopo   TEXT NOT NULL DEFAULT 'all',
    ativo    INTEGER NOT NULL DEFAULT 1
);
EOF

    # Postura de segurança padrão: banco de dados restrito ao dono (defesa em profundidade)
    chmod 600 "$db_path" 2>/dev/null || true
}

# Verifica se o arquivo com o hash específico já está no banco de dados
verificar_hash_existente() {
    local arquivo="$1"
    local hash_val="$2"
    local db_path
    db_path=$(obter_db_path)

    local count
    count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM document_chunks WHERE caminho_arquivo = '$arquivo' AND hash_arquivo = '$hash_val';")
    
    if [ "$count" -gt 0 ]; then
        return 0 # Encontrado (Cache válido)
    else
        return 1 # Não encontrado (Precisa reprocessar)
    fi
}

# Remove os blocos antigos de um arquivo (usado na reindexação)
limpar_registros_arquivo() {
    local arquivo="$1"
    local db_path
    db_path=$(obter_db_path)

    sqlite3 "$db_path" "DELETE FROM document_chunks WHERE caminho_arquivo = '$arquivo';"
}

# Insere um bloco e seu vetor de embedding no banco de dados
salvar_bloco_vetorial() {
    local arquivo="$1"
    local hash_val="$2"
    local idx="$3"
    local texto="$4"
    local vetor="$5"
    local db_path
    db_path=$(obter_db_path)

    # Escapa aspas simples no texto para o SQLite de forma segura
    local texto_escapado
    texto_escapado=$(echo "$texto" | sed "s/'/''/g")

    sqlite3 "$db_path" "INSERT INTO document_chunks (caminho_arquivo, hash_arquivo, chunk_index, conteudo_texto, vetor_embedding) VALUES ('$arquivo', '$hash_val', $idx, '$texto_escapado', '$vetor');"
}

# Realiza a busca vetorial por similaridade de cosseno (com suporte a filtro dinâmico de acervo)
# Retorna um array JSON contendo os trechos de texto mais semelhantes
buscar_trechos_relevantes() {
    local vetor_pergunta="$1"
    local query_original="$2"
    local limite=10
    local db_path
    db_path=$(obter_db_path)

    if [ ! -f "$db_path" ]; then
        echo "[]"
        return
    fi

    # Filtro de acervo dinâmico por metadados (número do processo) + filtro de clearance RAGSEC
    local condicoes=()

    # Escopo explícito de documentos (sessão da GUI web, via variável de ambiente
    # SCOPE_DOCS). Quando ativo, substitui o filtro heurístico por número de
    # processo: a seleção manual do usuário tem precedência sobre a inferência
    # automática (ver Review Finding #7 do plano multi_doc_scope_selector.md).
    local scope_in=""
    if [ -n "${SCOPE_DOCS:-}" ]; then
        # jq escapa aspas simples (gsub) e monta a lista IN com literais SQL seguros
        scope_in=$(echo "$SCOPE_DOCS" | jq -r "map(\"'\" + gsub(\"'\"; \"''\") + \"'\") | join(\",\")" 2>/dev/null || echo "")
    fi

    if [ -n "$scope_in" ]; then
        condicoes+=("caminho_arquivo IN ($scope_in)")
        local scope_count
        scope_count=$(echo "$SCOPE_DOCS" | jq 'length' 2>/dev/null || echo "?")
        echo -e "${YELLOW}[Escopo de Documentos Ativo: $scope_count doc(s) selecionado(s)]${NC}" >&2
    elif [ -n "$query_original" ]; then
        # Extrai número de processo (4 dígitos + ponto opcional + 10 dígitos)
        local reg_num
        reg_num=$(echo "$query_original" | grep -oE '[0-9]{4}\.?[0-9]{10}' | head -n 1 || echo "")
        if [ -z "$reg_num" ]; then
            # Alternativamente, busca qualquer padrão numérico longo no texto (ex: 5+ dígitos)
            reg_num=$(echo "$query_original" | grep -oE '[0-9]{5,}' | head -n 1 || echo "")
        fi

        if [ -n "$reg_num" ]; then
            local reg_clean
            reg_clean=${reg_num//./}
            condicoes+=("(caminho_arquivo LIKE '%$reg_num%' OR replace(caminho_arquivo, '.', '') LIKE '%$reg_clean%')")
            # Imprime aviso visual na stderr (pois stdout retorna o JSON)
            echo -e "${YELLOW}[Filtro de Acervo Ativo: $reg_num (Buscando apenas neste arquivo)]${NC}" >&2
        fi
    fi

    # RAGSEC: injeta filtro de clearance server-side (não é fornecido pelo usuário)
    if [ "${RAGSEC_MODE:-0}" = "1" ]; then
        local clausula_clearance
        clausula_clearance=$(filtro_clearance_sql "${RAGSEC_CLEARANCE:-0}")
        condicoes+=("$clausula_clearance")
    fi

    local where_clause=""
    if [ ${#condicoes[@]} -gt 0 ]; then
        local joined
        joined=$(IFS=' AND '; echo "${condicoes[*]}")
        where_clause="WHERE $joined"
    fi

    # Recupera os chunks filtrados ou todos serializados em formato JSON
    local dados_json
    dados_json=$(sqlite3 "$db_path" "SELECT json_object('caminho', caminho_arquivo, 'texto', conteudo_texto, 'vetor', json(vetor_embedding)) FROM document_chunks $where_clause;" 2>/dev/null || echo "")

    if [ -z "$dados_json" ]; then
        echo "[]"
        return
    fi

    # Transforma as linhas JSON retornadas pelo SQLite em uma lista/array JSON unificado para o JQ
    local array_completo
    array_completo=$(echo "$dados_json" | jq -s '.')

    # Executa o cálculo de similaridade de cosseno em lote usando JQ
    echo "$array_completo" | jq -c \
        --argjson q "$vetor_pergunta" \
        --argjson top "$limite" \
        '
        def dot_product(a; b):
          a as $a | b as $b |
          reduce range(0; $a | length) as $i (0; . + ($a[$i] * $b[$i]));
        
        def magnitude(a):
          a as $a |
          reduce range(0; $a | length) as $i (0; . + ($a[$i] * $a[$i])) | sqrt;
        
        def cosine_similarity(a; b):
          magnitude(a) as $magA |
          magnitude(b) as $magB |
          if ($magA * $magB) == 0 then
            0
          else
            dot_product(a; b) / ($magA * $magB)
          end;

        map(. + {similarity: cosine_similarity(.vetor; $q)})
        | sort_by(-.similarity)
        | limit($top; .[])
        | {caminho: .caminho, texto: .texto, score: .similarity}
        ' | jq -s '.'
}

# Busca trechos relevantes nos anexos de sessão da interface Web (backlog item
# 9: "Attach files to instantly add new RAG context (session-scoped)").
#
# Estes trechos vivem na tabela session_embeddings de web/data/chat_history.db
# (banco GUI-owned, separado do acervo global .cache_vetorial/rag_store.db) e
# NUNCA são persistidos no acervo global. Ativa apenas quando o chamador
# (src/rag_query.sh, disparado por web/app.py) define SESSION_EMBED_DB e
# SESSION_ID; ausência de qualquer um dos dois (uso normal via CLI/jus.sh)
# retorna [] sem custo.
buscar_trechos_sessao() {
    local vetor_pergunta="$1"
    local db_path="${SESSION_EMBED_DB:-}"
    local session_id="${SESSION_ID:-}"
    local limite=5

    if [ -z "$db_path" ] || [ -z "$session_id" ] || [ ! -f "$db_path" ]; then
        echo "[]"
        return
    fi

    # session_id é sempre um inteiro gerado pelo Flask (AUTOINCREMENT id) -
    # validação defensiva para nunca interpolar entrada arbitrária no SQL.
    if ! [[ "$session_id" =~ ^[0-9]+$ ]]; then
        echo "[]"
        return
    fi

    local dados_json
    dados_json=$(sqlite3 "$db_path" "SELECT json_object('caminho', ('📎 ' || file_name), 'texto', text, 'vetor', json(embedding)) FROM session_embeddings WHERE session_id = $session_id;" 2>/dev/null || echo "")

    if [ -z "$dados_json" ]; then
        echo "[]"
        return
    fi

    local array_completo
    array_completo=$(echo "$dados_json" | jq -s '.')

    echo "$array_completo" | jq -c \
        --argjson q "$vetor_pergunta" \
        --argjson top "$limite" \
        '
        def dot_product(a; b):
          a as $a | b as $b |
          reduce range(0; $a | length) as $i (0; . + ($a[$i] * $b[$i]));

        def magnitude(a):
          a as $a |
          reduce range(0; $a | length) as $i (0; . + ($a[$i] * $a[$i])) | sqrt;

        def cosine_similarity(a; b):
          magnitude(a) as $magA |
          magnitude(b) as $magB |
          if ($magA * $magB) == 0 then
            0
          else
            dot_product(a; b) / ($magA * $magB)
          end;

        map(. + {similarity: cosine_similarity(.vetor; $q)})
        | sort_by(-.similarity)
        | limit($top; .[])
        | {caminho: .caminho, texto: .texto, score: .similarity}
        ' | jq -s '.'
}

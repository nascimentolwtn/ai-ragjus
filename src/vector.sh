#!/bin/bash
# =========================================================================
# AI-RAGJus - Módulo de Banco de Dados Vetorial (SQLite + Busca de Cosseno)
# =========================================================================

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

# Realiza a busca vetorial por similaridade de cosseno
# Retorna um array JSON contendo os 3 trechos de texto mais semelhantes
buscar_trechos_relevantes() {
    local vetor_pergunta="$1"
    local limite=3
    local db_path
    db_path=$(obter_db_path)

    if [ ! -f "$db_path" ]; then
        echo "[]"
        return
    fi

    # Recupera todos os chunks cadastrados serializados em formato JSON
    # Isso evita problemas com quebras de linha no texto
    local dados_json
    dados_json=$(sqlite3 "$db_path" "SELECT json_object('caminho', caminho_arquivo, 'texto', conteudo_texto, 'vetor', json(vetor_embedding)) FROM document_chunks;")

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
          reduce range(0; a | length) as $i (0; . + (a[$i] * b[$i]));
        
        def magnitude(a):
          reduce range(0; a | length) as $i (0; . + (a[$i] * a[$i])) | sqrt;
        
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

#!/bin/bash
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/src/config.sh"
source "$APP_DIR/src/vector.sh"

carregar_configuracoes "$APP_DIR"

db_path=$(obter_db_path)
echo "Lendo dados do SQLite..."
dados_json=$(sqlite3 "$db_path" "SELECT json_object('caminho', caminho_arquivo, 'texto', conteudo_texto, 'vetor', json(vetor_embedding)) FROM document_chunks;")

echo "Passo 1: Slurping para array..."
array_completo=$(echo "$dados_json" | jq -s '.')
echo "Passo 1 OK. Tamanho do array: $(echo "$array_completo" | jq '. | length') elementos."

vetor_fake=$(jq -n '[range(768) | 0.01]')

echo "Passo 2: Executando cálculo de similaridade e ordenação..."
echo "$array_completo" | jq -c \
    --argjson q "$vetor_fake" \
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
    ' > /dev/null

echo "Passo 2 OK."

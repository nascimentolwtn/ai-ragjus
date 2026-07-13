#!/bin/bash
# =========================================================================
# AI-RAGJus - Ponte não-interativa para a interface Web (Flask)
# =========================================================================
# Executa o fluxo completo do LIG (embedding -> busca vetorial -> prompt ->
# geração) reaproveitando as mesmas funções usadas pelo jus.sh, mas emitindo
# eventos em JSON (uma linha por evento) em vez de texto colorido interativo.
#
# Uso: NON_INTERACTIVE=1 bash src/rag_query.sh "pergunta do usuário"
#
# Eventos emitidos em stdout (um objeto JSON por linha):
#   {"type":"sources","content":[{"caminho":...,"score":...}, ...]}
#   {"type":"token","content":"..."}      (um por token gerado pelo modelo)
#   {"type":"error","content":"..."}
#   {"type":"done"}
set -eo pipefail

# Força modo não-interativo independente do chamador (garante saída limpa em JSON)
export NON_INTERACTIVE=1

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

modulos=("config.sh" "ai.sh" "ingest.sh" "vector.sh")
for modulo in "${modulos[@]}"; do
    if [ -f "$APP_DIR/src/$modulo" ]; then
        source "$APP_DIR/src/$modulo"
    else
        jq -cn --arg msg "Módulo não encontrado em src/$modulo" '{type:"error", content:$msg}'
        echo '{"type":"done"}'
        exit 1
    fi
done

carregar_configuracoes "$APP_DIR"

query="$1"

if [ -z "$query" ]; then
    jq -cn '{type:"error", content:"Pergunta vazia."}'
    echo '{"type":"done"}'
    exit 1
fi

# 1. Gera embedding para a pergunta
vetor_query=$(gerar_embedding "$query" 2>/dev/null || echo "")

if [ -z "$vetor_query" ]; then
    jq -cn '{type:"error", content:"Falha ao processar embedding da pergunta. O Ollama está rodando?"}'
    echo '{"type":"done"}'
    exit 1
fi

# 2. Busca trechos semelhantes (passa a query original para filtro de acervo)
trechos=$(buscar_trechos_relevantes "$vetor_query" "$query" 2>/dev/null || echo "[]")

# 3. Serializa as fontes localizadas (nome do arquivo + score) para a UI
fontes_json=$(echo "$trechos" | jq -c '[.[] | {caminho: .caminho, score: .score}]' 2>/dev/null || echo "[]")
echo "{\"type\":\"sources\",\"content\":$fontes_json}"

# 4. Formata contexto
contexto=$(echo "$trechos" | jq -r '.[] | "Arquivo: " + .caminho + "\nTrecho: " + .texto + "\n---"' 2>/dev/null || echo "")

# Consulta estatísticas do acervo local no SQLite para evitar alucinações da IA
db_path=$(obter_db_path)
total_arquivos=$(sqlite3 "$db_path" "SELECT COUNT(DISTINCT caminho_arquivo) FROM document_chunks;" 2>/dev/null || echo "0")
arquivos_nomes=$(sqlite3 "$db_path" "SELECT DISTINCT caminho_arquivo FROM document_chunks;" 2>/dev/null | awk -F/ '{print $NF}' | sort -u | paste -sd ", " - || echo "")

# 5. Monta o prompt RAG (idêntico ao usado pelo jus.sh)
if [ -n "$contexto" ]; then
    prompt="Você é um assistente jurídico especialista de elite. Baseado nos trechos de documentos fornecidos abaixo e nos metadados reais do acervo local, responda de forma clara e objetiva à pergunta do usuário.

Metadados do Acervo Local:
- Total de arquivos jurídicos indexados: $total_arquivos
- Nomes dos arquivos no acervo: $arquivos_nomes

Documentos Jurídicos de Contexto:
$contexto

Pergunta do Usuário:
$query"
else
    prompt="Você é um assistente jurídico de elite. Diga de forma amigável e profissional que seu acervo local de documentos jurídicos está vazio ou não possui informações correlacionadas à pergunta, e oriente o usuário a colocar documentos na pasta de destino correspondente e reindexar.

Pergunta do Usuário:
$query"
fi

# 6. Gera a resposta (perguntar_ollama já emite tokens em JSON quando NON_INTERACTIVE=1)
perguntar_ollama "$prompt"

echo '{"type":"done"}'

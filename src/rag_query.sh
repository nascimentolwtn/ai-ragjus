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
#
# Escopo de documentos (opcional): defina SCOPE_DOCS como um array JSON de
# caminhos absolutos para restringir a busca/prompt a esse subconjunto do
# acervo (ver .claude/plans/multi_doc_scope_selector.md). Teste manual:
#
#   # Baseline (sem escopo)
#   NON_INTERACTIVE=1 bash src/rag_query.sh "uma pergunta qualquer" | jq '.sources | length'
#
#   # Escopo para um único documento
#   DOC=$(sqlite3 .cache_vetorial/rag_store.db "SELECT DISTINCT caminho_arquivo FROM document_chunks LIMIT 1;")
#   SCOPE_DOCS=$(jq -cn --arg d "$DOC" '[$d]') NON_INTERACTIVE=1 bash src/rag_query.sh "pergunta" \
#     | jq -r '.sources[].caminho' | sort -u
#
#   # SCOPE_DOCS malformado → cai no acervo completo, sem crash
#   SCOPE_DOCS='invalid-json' NON_INTERACTIVE=1 bash src/rag_query.sh "pergunta" | jq '.sources | length'
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

# Sanitiza SCOPE_DOCS: precisa ser um array JSON de strings (caminhos absolutos).
# Qualquer coisa diferente disso é descartada silenciosamente e o fluxo cai de
# volta para o acervo completo (nunca deve travar a consulta).
if [ -n "${SCOPE_DOCS:-}" ]; then
    if ! echo "$SCOPE_DOCS" | jq -e 'type == "array" and all(type == "string")' >/dev/null 2>&1; then
        unset SCOPE_DOCS
    fi
fi

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

# Consulta estatísticas do acervo local no SQLite para evitar alucinações da IA.
# Quando SCOPE_DOCS está ativo, restringe as estatísticas ao subconjunto
# escolhido — do contrário o modelo seria informado sobre documentos que não
# pode citar (Review Finding #8 do plano multi_doc_scope_selector.md).
db_path=$(obter_db_path)
scope_in_meta=""
if [ -n "${SCOPE_DOCS:-}" ]; then
    scope_in_meta=$(echo "$SCOPE_DOCS" | jq -r "map(\"'\" + gsub(\"'\"; \"''\") + \"'\") | join(\",\")" 2>/dev/null || echo "")
fi

if [ -n "$scope_in_meta" ]; then
    echo -e "${YELLOW}[Escopo: metadados do prompt restritos a $(echo "$SCOPE_DOCS" | jq 'length') doc(s)]${NC}" >&2
    total_arquivos=$(sqlite3 "$db_path" "SELECT COUNT(DISTINCT caminho_arquivo) FROM document_chunks WHERE caminho_arquivo IN ($scope_in_meta);" 2>/dev/null || echo "0")
    arquivos_nomes=$(sqlite3 "$db_path" "SELECT DISTINCT caminho_arquivo FROM document_chunks WHERE caminho_arquivo IN ($scope_in_meta);" 2>/dev/null | awk -F/ '{print $NF}' | sort -u | paste -sd ", " - || echo "")
else
    total_arquivos=$(sqlite3 "$db_path" "SELECT COUNT(DISTINCT caminho_arquivo) FROM document_chunks;" 2>/dev/null || echo "0")
    arquivos_nomes=$(sqlite3 "$db_path" "SELECT DISTINCT caminho_arquivo FROM document_chunks;" 2>/dev/null | awk -F/ '{print $NF}' | sort -u | paste -sd ", " - || echo "")
fi

# 5. Monta o prompt RAG (idêntico ao usado pelo jus.sh, + bloco opcional de
#    memória via RAG_MEMORY_CONTEXT - ver .claude/plans/flask_gui_backlog_implementation.md M0)
memoria_bloco=""
if [ -n "${RAG_MEMORY_CONTEXT:-}" ]; then
    memoria_bloco="

Contexto de Memória (fatos conhecidos desta conversa e do usuário):
$RAG_MEMORY_CONTEXT"
fi

if [ -n "$contexto" ]; then
    prompt="Você é um assistente jurídico especialista de elite. Baseado nos trechos de documentos fornecidos abaixo e nos metadados reais do acervo local, responda de forma clara e objetiva à pergunta do usuário.

Metadados do Acervo Local:
- Total de arquivos jurídicos indexados: $total_arquivos
- Nomes dos arquivos no acervo: $arquivos_nomes$memoria_bloco

Documentos Jurídicos de Contexto:
$contexto

Pergunta do Usuário:
$query"
else
    prompt="Você é um assistente jurídico de elite. Diga de forma amigável e profissional que seu acervo local de documentos jurídicos está vazio ou não possui informações correlacionadas à pergunta, e oriente o usuário a colocar documentos na pasta de destino correspondente e reindexar.$memoria_bloco

Pergunta do Usuário:
$query"
fi

# 6. Gera a resposta (perguntar_ollama já emite tokens em JSON quando NON_INTERACTIVE=1)
perguntar_ollama "$prompt"

echo '{"type":"done"}'

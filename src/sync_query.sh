#!/bin/bash
# =========================================================================
# AI-RAGJus - Ponte não-interativa de sincronização para a interface Web (Flask)
# =========================================================================
# Executa sincronizar_documentos() (mesma função usada pelo jus.sh, opção 2)
# reaproveitando o motor de ingestão, mas emitindo eventos em JSON (uma linha
# por evento) em vez de texto colorido interativo, para consumo via SSE.
#
# Uso: NON_INTERACTIVE=1 bash src/sync_query.sh
#
# Eventos emitidos em stdout (um objeto JSON por linha):
#   {"type":"progress","content":"..."}                              (uma por linha de progresso da sincronização)
#   {"type":"error","content":"..."}                                 (erro pontual - ex: falha de embedding num bloco)
#   {"type":"complete","chunks_count":N,"files_count":M}             (resumo final, só emitido em caso de sucesso)
#   {"type":"done"}                                                  (sempre a última linha)
set -eo pipefail

# Força modo não-interativo independente do chamador (garante saída limpa em JSON)
export NON_INTERACTIVE=1

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Nota: propositalmente NÃO sourceamos ui.sh aqui (assim como rag_query.sh) -
# isso deixa GREEN/YELLOW/BLUE/RED/NC vazios (definidos por ai.sh quando
# NON_INTERACTIVE=1), evitando códigos ANSI misturados nas linhas de
# progresso que emitimos como JSON.
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

if [ ! -d "$PASTA_ALVO" ]; then
    jq -cn --arg msg "A pasta de documentos '$PASTA_ALVO' não existe ou não está acessível." '{type:"error", content:$msg}'
    echo '{"type":"done"}'
    exit 1
fi

jq -cn --arg msg "Sincronização iniciada em: $PASTA_ALVO" '{type:"progress", content:$msg}'

# Executa a sincronização e converte cada linha de saída (stdout+stderr) em
# eventos JSON. Linhas que já são objetos JSON válidos (ex: erros emitidos
# por gerar_embedding/perguntar_ollama em NON_INTERACTIVE) são repassadas
# como estão; o restante (texto de progresso comum) é envelopado.
while IFS= read -r linha || [ -n "$linha" ]; do
    [ -z "$linha" ] && continue
    if echo "$linha" | jq -e 'type == "object" and has("type")' >/dev/null 2>&1; then
        echo "$linha"
    else
        jq -cn --arg msg "$linha" '{type:"progress", content:$msg}'
    fi
done < <(sincronizar_documentos 2>&1)

# Resumo final a partir do estado real do banco (best-effort mesmo se algum
# arquivo individual falhou durante a varredura acima).
db_path=$(obter_db_path)
total_chunks=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM document_chunks;" 2>/dev/null || echo "0")
total_arquivos=$(sqlite3 "$db_path" "SELECT COUNT(DISTINCT caminho_arquivo) FROM document_chunks;" 2>/dev/null || echo "0")

jq -cn --argjson chunks "${total_chunks:-0}" --argjson arquivos "${total_arquivos:-0}" \
    '{type:"complete", chunks_count:$chunks, files_count:$arquivos}'
echo '{"type":"done"}'

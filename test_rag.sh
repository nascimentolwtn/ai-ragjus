#!/bin/bash
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$APP_DIR/src/config.sh"
source "$APP_DIR/src/vector.sh"

carregar_configuracoes "$APP_DIR"

# Gera um vetor fake de 768 dimensões com valores 0.01 para teste
echo "Gerando vetor de teste de 768 dimensões..."
vetor_fake=$(jq -n '[range(768) | 0.01]')

echo "Medindo tempo de busca vetorial no SQLite + JQ..."
start_time=$(date +%s)

trechos=$(buscar_trechos_relevantes "$vetor_fake")

end_time=$(date +%s)
duration=$((end_time - start_time))

echo "Busca concluída em $duration segundos."
echo "Resultados da busca (tamanho da string): ${#trechos} caracteres."
echo "Primeiros 300 caracteres dos resultados:"
echo "${trechos:0:300}"

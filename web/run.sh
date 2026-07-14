#!/bin/bash
# =========================================================================
# AI-RAGJus - Launcher da Interface Web (Flask)
# =========================================================================
# Sobe o Flask em modo NON_INTERACTIVE, reaproveitando config.conf e os
# módulos src/*.sh via subprocess (ver web/app.py e src/rag_query.sh).
# Uso: ./web/run.sh
set -eo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR"

export NON_INTERACTIVE=1

# Ativa virtualenv local se existir (opcional)
if [ -f "$APP_DIR/venv/bin/activate" ]; then
    # shellcheck disable=SC1091
    source "$APP_DIR/venv/bin/activate"
fi

if ! command -v python3 &> /dev/null; then
    echo "[ERRO] python3 não encontrado. Instale o Python 3 para rodar a interface web." >&2
    exit 1
fi

if ! python3 -c "import flask" &> /dev/null; then
    echo "[AVISO] Flask não encontrado no interpretador Python atual." >&2
    echo "        Instale com: pip install -r web/requirements.txt" >&2
    exit 1
fi

echo "Verificando Ollama em $(grep '^OLLAMA_URL' config.conf 2>/dev/null || echo 'http://localhost:11434')..."
curl -s --max-time 2 http://localhost:11434 > /dev/null 2>&1 \
    && echo "[OK] Ollama respondendo." \
    || echo "[AVISO] Não foi possível contatar o Ollama agora; o chat retornará erro até que o serviço esteja no ar."

LOCAL_IP=$(hostname -I | awk '{print $1}')
echo "Iniciando AI-RAGJus Web GUI..."
echo "  Acesso local: http://127.0.0.1:5000"
echo "  Acesso na rede: http://${LOCAL_IP}:5000"
echo "  (Ctrl+C para encerrar)"
exec python3 "$APP_DIR/web/app.py"

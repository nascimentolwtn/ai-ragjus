#!/bin/bash

# Dual Ollama instances for AI-RAGJus
# GPU instance on 11434 (inference)
# CPU instance on 11435 (embeddings)

set -e

LOG_DIR="${HOME}/.ollama/logs"
mkdir -p "$LOG_DIR"

CPU_LOG="$LOG_DIR/ollama-cpu.log"
GPU_LOG="$LOG_DIR/ollama-gpu.log"

# Clear old logs
> "$CPU_LOG"
> "$GPU_LOG"

stop_instances() {
  echo "[*] Stopping and removing old containers..."
  docker stop ollama-cpu ollama-gpu 2>/dev/null || true
  docker rm ollama-cpu ollama-gpu 2>/dev/null || true
}

# If "stop" argument is passed, stop instances and exit
if [[ "$1" == "stop" ]]; then
  stop_instances
  exit 0
fi

# Proceed with normal startup flow
stop_instances

echo "[*] Starting GPU instance on port 11434..."
docker run -d --name ollama-gpu \
  --network host \
  --gpus all \
  -v /usr/share/ollama/.ollama/models:/root/.ollama/models \
  -v ~/models-llm:/home/root/models-llm \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e OLLAMA_HOST=127.0.0.1:11434 \
  -e OLLAMA_KEEP_ALIVE=24h \
  -e OLLAMA_MAX_LOADED_MODELS=1 \
  -e OLLAMA_FLASH_ATTENTION=1 \
  ollama/ollama:latest serve

echo "[*] Starting CPU-only instance on port 11435..."
docker run -d --name ollama-cpu \
  --network host \
  -v /usr/share/ollama/.ollama/models:/root/.ollama/models \
  -v ~/models-llm:/home/root/models-llm \
  -e CUDA_VISIBLE_DEVICES="" \
  -e OLLAMA_HOST=127.0.0.1:11435 \
  -e OLLAMA_KEEP_ALIVE=24h \
  -e OLLAMA_MAX_LOADED_MODELS=1 \
  -e OLLAMA_FLASH_ATTENTION=0 \
  ollama/ollama:latest serve

sleep 2

echo "[*] Both instances started. Monitoring logs (Ctrl+C to stop)..."
echo ""

# Function to display logs with prefix and save to file
show_logs() {
  local container=$1
  local prefix=$2
  local logfile=$3
  docker logs -f "$container" 2>&1 | sed "s/^/$prefix /" | tee "$logfile"
}

# Start both log streams in the background
show_logs ollama-gpu "[GPU-11434]" "$GPU_LOG" &
GPU_PID=$!

show_logs ollama-cpu "[CPU-11435]" "$CPU_LOG" &
CPU_PID=$!

# Trap Ctrl+C to stop both background jobs
trap "kill $CPU_PID $GPU_PID 2>/dev/null || true" EXIT INT TERM

# Wait for both
wait $CPU_PID $GPU_PID 2>/dev/null || true

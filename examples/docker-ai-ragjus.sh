#!/bin/bash

# Dual Ollama instances for AI-RAGJus
# CPU instance on 11434 (embeddings)
# GPU instance on 11435 (inference)

set -e

echo "[*] Stopping and removing old containers..."
docker stop ollama-cpu ollama-gpu 2>/dev/null || true
docker rm ollama-cpu ollama-gpu 2>/dev/null || true

echo "[*] Starting CPU-only instance on port 11434..."
docker run -d --name ollama-cpu \
  --network host \
  -v /usr/share/ollama/.ollama/models:/root/.ollama/models \
  -v ~/models-llm:/home/root/models-llm \
  -e CUDA_VISIBLE_DEVICES="" \
  -e OLLAMA_HOST=127.0.0.1:11434 \
  -e OLLAMA_KEEP_ALIVE=4h \
  -e OLLAMA_FLASH_ATTENTION=0 \
  ollama/ollama:latest serve

echo "[*] Starting GPU instance on port 11435..."
docker run -d --name ollama-gpu \
  --network host \
  --gpus all \
  -v /usr/share/ollama/.ollama/models:/root/.ollama/models \
  -v ~/models-llm:/home/root/models-llm \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e OLLAMA_HOST=127.0.0.1:11435 \
  -e OLLAMA_KEEP_ALIVE=4h \
  -e OLLAMA_MAX_LOADED_MODELS=2 \
  -e OLLAMA_FLASH_ATTENTION=1 \
  ollama/ollama:latest serve

sleep 2

echo "[*] Both instances started. Monitoring logs (Ctrl+C to stop)..."
echo ""
echo "========== CPU Instance (11434) =========="
echo ""

# Function to display logs with prefix
show_logs() {
  local container=$1
  local prefix=$2
  docker logs -f "$container" 2>&1 | sed "s/^/$prefix /"
}

# Start both log streams in the background
show_logs ollama-cpu "[CPU-11434]" &
CPU_PID=$!

show_logs ollama-gpu "[GPU-11435]" &
GPU_PID=$!

# Trap Ctrl+C to stop both background jobs
trap "kill $CPU_PID $GPU_PID 2>/dev/null || true" EXIT INT TERM

# Wait for both
wait $CPU_PID $GPU_PID 2>/dev/null || true

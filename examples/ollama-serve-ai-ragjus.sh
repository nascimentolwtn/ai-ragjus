#!/bin/bash

# Dual Ollama instances for AI-RAGJus (native)
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

cleanup() {
  echo ""
  echo "[*] Stopping Ollama instances..."
  pkill -f "ollama serve.*11434" 2>/dev/null || true
  pkill -f "ollama serve.*11435" 2>/dev/null || true
  sleep 1
}

trap cleanup EXIT INT TERM

echo "[*] Starting GPU instance on port 11434..."
CUDA_VISIBLE_DEVICES=0 ollama serve --addr 127.0.0.1:11434 >> "$GPU_LOG" 2>&1 &
GPU_PID=$!

echo "[*] Starting CPU-only instance on port 11435..."
CUDA_VISIBLE_DEVICES="" ollama serve --addr 127.0.0.1:11435 >> "$CPU_LOG" 2>&1 &
CPU_PID=$!

sleep 2

echo "[*] Both instances started. Monitoring logs (Ctrl+C to stop)..."
echo ""

# Function to display logs with prefix
show_logs_with_prefix() {
  local logfile=$1
  local prefix=$2
  tail -F "$logfile" 2>/dev/null | sed "s/^/$prefix /" &
}

show_logs_with_prefix "$GPU_LOG" "[GPU-11434]"
show_logs_with_prefix "$CPU_LOG" "[CPU-11435]"

# Keep script running until interrupted
wait $CPU_PID $GPU_PID 2>/dev/null || true

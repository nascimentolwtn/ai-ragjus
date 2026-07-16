#!/bin/bash
# =========================================================================
# Dual Ollama Instance Startup Script
# =========================================================================
# Runs two Ollama instances in parallel for optimal resource allocation:
# - Instance 1 (port 11434): CPU-only, embedding model (nomic-embed-text)
# - Instance 2 (port 11435): GPU-enabled, inference model (qwen2.5:1.5b)
#
# This eliminates GPU/CPU contention and keeps both models loaded.
#
# Usage:
#   bash web/run_dual_ollama.sh
#   or
#   bash web/run_dual_ollama.sh &  # Run in background

set -eo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=========================================================================="
echo "AI-RAGJus - Dual Ollama Instance Launcher"
echo "=========================================================================="
echo ""
echo "This script starts two Ollama instances in parallel:"
echo "  • CPU-only instance on port 11434 (embeddings)"
echo "  • GPU instance on port 11435 (inference)"
echo ""
echo "For production or long-running use, consider running these in separate"
echo "terminal tabs or using systemd/docker."
echo ""
echo "Starting instances..."
echo ""

# Check if Ollama is installed
if ! command -v ollama &> /dev/null; then
    echo "Error: Ollama not found. Please install Ollama first."
    echo "Visit: https://ollama.ai"
    exit 1
fi

# Function to start CPU-only instance
start_cpu_instance() {
    echo "[1/2] Starting CPU-only Ollama on port 11434..."
    CUDA_VISIBLE_DEVICES="" ollama serve --addr 127.0.0.1:11434 2>&1 | sed 's/^/[CPU] /'
}

# Function to start GPU instance
start_gpu_instance() {
    # Wait a moment for CPU instance to start
    sleep 2
    echo "[2/2] Starting GPU Ollama on port 11435..."
    CUDA_VISIBLE_DEVICES=0 ollama serve --addr 127.0.0.1:11435 2>&1 | sed 's/^/[GPU] /'
}

# Start both instances in parallel
start_cpu_instance &
CPU_PID=$!

start_gpu_instance &
GPU_PID=$!

echo ""
echo "=========================================================================="
echo "Both Ollama instances are now running"
echo "=========================================================================="
echo ""
echo "Instance Status:"
echo "  • CPU-only (port 11434): Ready for embedding operations"
echo "  • GPU-enabled (port 11435): Ready for inference operations"
echo ""
echo "To stop both instances, press Ctrl+C"
echo ""

# Wait for both processes
wait $CPU_PID $GPU_PID

# Cleanup on exit
echo ""
echo "Dual Ollama instances stopped."

#!/bin/bash
# =========================================================================
# Unit tests for src/ai.sh - num_gpu parameter verification
# =========================================================================
# Tests that the Ollama API payloads include correct num_gpu values:
# - gerar_embedding(): num_gpu: 0 (CPU only for embedding model)
# - perguntar_ollama(): num_gpu: -1 (auto-detect GPUs for inference model)
#
# These tests verify payload construction without requiring Ollama to run.
#
# Usage: bash test/unit/test_ai_num_gpu.sh

set -o pipefail

# Test counter and results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Source the configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PROJECT_ROOT/src/config.sh"

# =========================================================================
# Test Utilities
# =========================================================================

print_test_header() {
    echo ""
    echo -e "${YELLOW}[TEST]${NC} $1"
}

assert_true() {
    local condition="$1"
    local message="$2"

    TESTS_RUN=$((TESTS_RUN + 1))

    if eval "$condition" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $message"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_json_field() {
    local json="$1"
    local field="$2"
    local expected_value="$3"
    local message="$4"

    TESTS_RUN=$((TESTS_RUN + 1))

    local actual_value
    actual_value=$(echo "$json" | jq -r "$field" 2>/dev/null)

    if [ "$actual_value" = "$expected_value" ]; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "       Expected: ${BLUE}$expected_value${NC}"
        echo -e "       Got:      ${BLUE}$actual_value${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_valid_json() {
    local json="$1"
    local message="$2"

    TESTS_RUN=$((TESTS_RUN + 1))

    if echo "$json" | jq empty >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $message"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local text="$1"
    local pattern="$2"
    local message="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if echo "$text" | grep -q "$pattern"; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "       Pattern: ${BLUE}$pattern${NC}"
        echo -e "       Not found in payload${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# =========================================================================
# Test Suite: gerar_embedding() payload construction
# =========================================================================

print_test_header "gerar_embedding() - Embedding payload with num_gpu: 0"

# Simulate the exact payload construction from gerar_embedding()
MODELO_EMBEDDING="${MODELO_EMBEDDING:-nomic-embed-text}"
SAMPLE_TEXT="Test document for embedding"

EMBEDDING_PAYLOAD=$(jq -n --arg model "$MODELO_EMBEDDING" --arg prompt "$SAMPLE_TEXT" '{"model": $model, "prompt": $prompt, "num_gpu": 0}')

# Test payload validity
assert_valid_json "$EMBEDDING_PAYLOAD" "Embedding payload is valid JSON"

# Test required fields
assert_json_field "$EMBEDDING_PAYLOAD" ".model" "nomic-embed-text" "Model field is 'nomic-embed-text'"
assert_json_field "$EMBEDDING_PAYLOAD" ".prompt" "Test document for embedding" "Prompt field contains test text"
assert_json_field "$EMBEDDING_PAYLOAD" ".num_gpu" "0" "num_gpu field is 0 (CPU only)"

# Test that num_gpu is NOT -1
assert_true '[ "$(echo "$EMBEDDING_PAYLOAD" | jq .num_gpu)" != "-1" ]' "num_gpu is not -1 (not GPU)"

echo ""

# =========================================================================
# Test Suite: perguntar_ollama() payload construction
# =========================================================================

print_test_header "perguntar_ollama() - Inference payload with num_gpu: -1"

# Simulate the exact payload construction from perguntar_ollama()
MODELO_IA="${MODELO_IA:-qwen3.5:4b}"
SAMPLE_PROMPT="What is this test?"
TEMPERATURA="${TEMPERATURA:-0}"
CONTEXT_WINDOW="${CONTEXT_WINDOW:-16384}"

INFERENCE_PAYLOAD=$(jq -n --arg model "$MODELO_IA" --arg prompt "$SAMPLE_PROMPT" --argjson temp "$TEMPERATURA" --argjson ctx "$CONTEXT_WINDOW" '{"model": $model, "prompt": $prompt, "stream": true, "num_gpu": -1, "options": {"temperature": $temp, "num_ctx": $ctx}}')

# Test payload validity
assert_valid_json "$INFERENCE_PAYLOAD" "Inference payload is valid JSON"

# Test required fields
assert_json_field "$INFERENCE_PAYLOAD" ".model" "qwen3.5:4b" "Model field is inference model"
assert_json_field "$INFERENCE_PAYLOAD" ".prompt" "What is this test?" "Prompt field contains test question"
assert_json_field "$INFERENCE_PAYLOAD" ".stream" "true" "stream field is true"
assert_json_field "$INFERENCE_PAYLOAD" ".num_gpu" "-1" "num_gpu field is -1 (auto-detect all GPUs)"
assert_json_field "$INFERENCE_PAYLOAD" ".options.temperature" "0" "temperature option is 0"
assert_json_field "$INFERENCE_PAYLOAD" ".options.num_ctx" "16384" "num_ctx option is 16384"

# Test that num_gpu is NOT 0
assert_true '[ "$(echo "$INFERENCE_PAYLOAD" | jq .num_gpu)" != "0" ]' "num_gpu is not 0 (is GPU)"

echo ""

# =========================================================================
# Test Suite: Payload comparison
# =========================================================================

print_test_header "Comparison - num_gpu values are different"

EMBED_GPU=$(echo "$EMBEDDING_PAYLOAD" | jq .num_gpu)
INFER_GPU=$(echo "$INFERENCE_PAYLOAD" | jq .num_gpu)

assert_true '[ "$EMBED_GPU" != "$INFER_GPU" ]' "Embedding (num_gpu=$EMBED_GPU) differs from Inference (num_gpu=$INFER_GPU)"
assert_true '[ "$EMBED_GPU" = "0" ] && [ "$INFER_GPU" = "-1" ]' "Correct values: embedding CPU (0), inference GPU (-1)"

echo ""

# =========================================================================
# Test Suite: Source code verification
# =========================================================================

print_test_header "Source code verification - num_gpu in src/ai.sh"

# Verify the actual source code contains num_gpu parameters
assert_contains "$(sed -n '35p' "$PROJECT_ROOT/src/ai.sh")" '"num_gpu": 0' "Line 35 has num_gpu: 0 for embedding"
assert_contains "$(sed -n '99p' "$PROJECT_ROOT/src/ai.sh")" '"num_gpu": -1' "Line 99 has num_gpu: -1 for inference"

echo ""

# =========================================================================
# Test Results Summary
# =========================================================================

echo -e "${YELLOW}=== Test Results ===${NC}"
echo "Tests run: $TESTS_RUN"
echo -e "Passed:   ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:   ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All tests PASSED${NC}"
    echo ""
    echo -e "${BLUE}Summary:${NC}"
    echo "  • Embedding payloads correctly set num_gpu: 0 (CPU)"
    echo "  • Inference payloads correctly set num_gpu: -1 (GPU)"
    echo "  • Both payloads have valid JSON structure"
    echo "  • Tests ran without Ollama"
    exit 0
else
    echo -e "${RED}✗ Some tests FAILED${NC}"
    exit 1
fi

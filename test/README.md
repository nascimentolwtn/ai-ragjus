# AI-RAGJus Unit Tests

Unit tests for the AI-RAGJus project. Tests verify functionality without requiring Ollama to be running.

## Quick Start

Run all unit tests:

```bash
bash test/run_unit_tests.sh
```

Or run a specific test file:

```bash
bash test/unit/test_ai_num_gpu.sh
```

## Test Structure

```
test/
├── README.md                      # This file
├── run_unit_tests.sh             # Test runner script
└── unit/
    └── test_ai_num_gpu.sh        # Unit tests for Ollama num_gpu parameters
```

## Available Tests

### test/unit/test_ai_num_gpu.sh

Verifies that the Ollama API payloads include correct GPU allocation parameters:

**Tests:**
- `gerar_embedding()` generates payload with `"num_gpu": 0` (embedding model on CPU)
- `perguntar_ollama()` generates payload with `"num_gpu": -1` (inference model on GPU)
- Both payloads have valid JSON structure
- Source code lines 35 and 99 contain the correct parameters

**Features:**
- Runs without requiring Ollama to be installed or running
- Tests payload construction directly without mocking curl
- 17 test assertions covering payload structure and field values

**Example output:**
```
✓ Embedding payload is valid JSON
✓ Model field is 'nomic-embed-text'
✓ num_gpu field is 0 (CPU only)
✓ Inference payload is valid JSON
✓ num_gpu field is -1 (auto-detect all GPUs)
...
✓ All tests PASSED (17/17)
```

## Running Tests Without Ollama

The test suite is designed to run without Ollama:

1. Tests verify payload construction using `jq`, not actual API calls
2. No mocking of curl needed
3. No network requests made
4. Can run in CI/CD pipelines, Docker, or air-gapped environments

## Requirements

- **bash** (v4.0+)
- **jq** (for JSON parsing)

## Test Framework

Uses a custom bash test framework (no BATS dependency required):

- Color-coded output (green/red for pass/fail)
- Multiple assertion types: `assert_json_field`, `assert_valid_json`, `assert_contains`
- Detailed failure messages with expected vs actual values
- Test counter and summary statistics

## Adding New Tests

Create a new test file in `test/unit/test_*.sh`:

```bash
#!/bin/bash
set -o pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PROJECT_ROOT/src/config.sh"

# ... import test utilities from existing test file ...

print_test_header "My Test Feature"
assert_true '[ 1 -eq 1 ]' "Basic assertion example"
```

The test runner will automatically discover and run files matching `test_*.sh`.

## CI/CD Integration

The test suite can be easily integrated into CI/CD pipelines:

```bash
# In your CI config:
bash test/run_unit_tests.sh || exit 1
```

Exit code: 0 on success, 1 on failure.

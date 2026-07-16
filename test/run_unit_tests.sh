#!/bin/bash
# =========================================================================
# Unit Test Runner
# =========================================================================
# Runs all unit tests in the test/unit/ directory without requiring
# external tools like BATS. Perfect for CI/CD pipelines and local testing.
#
# Usage: bash test/run_unit_tests.sh

set -o pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_TEST_DIR="$PROJECT_ROOT/test/unit"

echo "=========================================================================="
echo "AI-RAGJus Unit Test Suite"
echo "=========================================================================="
echo ""

# Check if unit test directory exists
if [ ! -d "$UNIT_TEST_DIR" ]; then
    echo "Error: test/unit/ directory not found at $UNIT_TEST_DIR"
    exit 1
fi

# Find and run all test files
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0

TEST_FILES=$(find "$UNIT_TEST_DIR" -name "test_*.sh" -type f | sort)

if [ -z "$TEST_FILES" ]; then
    echo "No test files found in $UNIT_TEST_DIR"
    exit 1
fi

for test_file in $TEST_FILES; do
    echo "Running: $(basename "$test_file")"
    echo "---"

    if bash "$test_file"; then
        TEST_STATUS="PASS"
    else
        TEST_STATUS="FAIL"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi

    echo ""
done

echo "=========================================================================="
echo "Summary: All test files completed"
echo "=========================================================================="
exit 0

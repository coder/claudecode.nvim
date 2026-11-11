#!/bin/bash

# Script to run integration tests individually to avoid plenary test_directory hanging
# Each test file is run separately with test_file

set -e
# pipefail: don't let `tee` mask a failing nvim in the pipe below
set -o pipefail

echo "=== Running Integration Tests Individually ==="

# Track overall results
TOTAL_SUCCESS=0
TOTAL_FAILED=0
TOTAL_ERRORS=0
FAILED_FILES=()

# Function to run a single test file
run_test_file() {
  local test_file=$1
  local basename
  basename=$(basename "$test_file")

  echo ""
  echo "Running: $basename"

  local temp_output group_file
  temp_output=$(mktemp)
  group_file=$(mktemp)

  # timeout runs nvim in a process group named after its own pid, which is this shell's pid until it execs timeout.
  if bash -c 'echo $$ > "$1"; shift; exec timeout -k 5s 30s "$@"' _ "$group_file" \
    nvim --headless -u tests/minimal_init.lua \
    -c "lua require('plenary.test_harness').test_file('$test_file', {minimal_init = 'tests/minimal_init.lua'})" \
    2>&1 | tee "$temp_output"; then
    EXIT_CODE=0
  else
    EXIT_CODE=$?
  fi

  # Parse results from output
  local clean_output
  clean_output=$(sed 's/\x1b\[[0-9;]*m//g' "$temp_output")
  local success_count
  success_count=$(echo "$clean_output" | grep -c "^Success[[:space:]]*||" || true)
  local failing_rows
  failing_rows=$(echo "$clean_output" | grep -c -E "^(Fail|Error)[[:space:]]*\|\|" || true)
  local failed_count
  failed_count=$(echo "$clean_output" | grep "^Failed :" | tail -1 | awk '{print $3}' || true)
  local error_count
  error_count=$(echo "$clean_output" | grep "^Errors :" | tail -1 | awk '{print $3}' || true)

  # Plenary prints its summary only after it has run the whole file. Without the counts, nvim stopped early,
  # whatever its exit code says.
  if [[ ! $failed_count =~ ^[0-9]+$ ]] || [[ ! $error_count =~ ^[0-9]+$ ]]; then
    echo "FAILED: $basename: no plenary summary (nvim exit $EXIT_CODE)"
    failed_count=0
    error_count=1
  fi
  if [[ $failing_rows -gt 0 ]]; then
    echo "FAILED: $basename: $failing_rows failing test row(s)"
    if [[ $failing_rows -gt $failed_count ]]; then
      failed_count=$failing_rows
    fi
  fi

  # Update totals
  TOTAL_SUCCESS=$((TOTAL_SUCCESS + success_count))
  TOTAL_FAILED=$((TOTAL_FAILED + failed_count))
  TOTAL_ERRORS=$((TOTAL_ERRORS + error_count))

  # Exit 124 is timeout's, 137 is its SIGKILL after 5 more seconds, and 143 is SIGTERM.
  if [[ $EXIT_CODE -eq 124 ]] || [[ $EXIT_CODE -eq 137 ]] || [[ $EXIT_CODE -eq 143 ]]; then
    echo "TIMEOUT: $basename was stopped (exit $EXIT_CODE): nvim did not exit within 30s"
    # nvim busy in a Lua loop ignores SIGTERM and outlives timeout.
    kill -KILL -- "-$(cat "$group_file")" 2>/dev/null || true
  fi

  # Check if test failed
  if [[ $failed_count -gt 0 ]] || [[ $error_count -gt 0 ]] || [[ $EXIT_CODE -ne 0 ]]; then
    FAILED_FILES+=("$basename")
  fi

  # Cleanup
  rm -f "$temp_output" "$group_file"
}

for test_file in tests/integration/*_spec.lua; do
  run_test_file "$test_file"
done

# Summary
echo ""
echo "========================================="
echo "Integration Test Summary"
echo "========================================="
echo "Total Success: $TOTAL_SUCCESS"
echo "Total Failed: $TOTAL_FAILED"
echo "Total Errors: $TOTAL_ERRORS"

if [[ ${#FAILED_FILES[@]} -gt 0 ]]; then
  echo ""
  echo "Failed test files:"
  for file in "${FAILED_FILES[@]}"; do
    echo "  - $file"
  done
fi

# Exit with appropriate code
if [[ ${#FAILED_FILES[@]} -eq 0 ]]; then
  echo ""
  echo "✅ All integration tests passed!"
  exit 0
else
  echo ""
  echo "❌ Some integration tests failed!"
  exit 1
fi

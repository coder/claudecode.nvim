#!/bin/bash

# Script to run integration tests individually to avoid plenary test_directory hanging
# Each test file is run separately with test_file

set -e
# pipefail: don't let `tee` mask a failing nvim in the pipe below
set -o pipefail

# How long timeout lets one file's nvim run. plenary's test_file ends a file at 50s on its own: exit 1, no TIMEOUT
# line, and its nvim left running. So this limit plus the 5s kill grace below must stay under 50s.
# selection_held_spec.lua sleeps 21.6s in 77 vim.wait calls, so 30s left each of them 0.1s of slack under load.
FILE_TIMEOUT=40s

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
  if bash -c 'echo $$ > "$1"; shift; exec timeout -k 5s "$@"' _ "$group_file" "$FILE_TIMEOUT" \
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
  local success_count failed_count error_count
  success_count=$(echo "$clean_output" | grep "^Success:" | tail -1 | awk '{print $2}' || true)
  failed_count=$(echo "$clean_output" | grep "^Failed :" | tail -1 | awk '{print $3}' || true)
  error_count=$(echo "$clean_output" | grep "^Errors :" | tail -1 | awk '{print $3}' || true)

  # Plenary prints its summary only after it has run the whole file. Without all three counts, nvim stopped early,
  # whatever its exit code says. A count that is not 0 or 1 to 9 digits without a leading zero would stop bash or wrap
  # in the arithmetic below. The digits are spelled out because [0-9] also matches other digits in some locales.
  local plain_count='^(0|[123456789][0123456789]{0,8})$'
  if [[ ! $success_count =~ $plain_count ]] || [[ ! $failed_count =~ $plain_count ]] || [[ ! $error_count =~ $plain_count ]]; then
    echo "FAILED: $basename: no plenary summary (nvim exit $EXIT_CODE)"
    success_count=0
    failed_count=0
    error_count=1
  fi

  # Update totals
  TOTAL_SUCCESS=$((TOTAL_SUCCESS + success_count))
  TOTAL_FAILED=$((TOTAL_FAILED + failed_count))
  TOTAL_ERRORS=$((TOTAL_ERRORS + error_count))

  # Exit 124 is timeout's, 137 is its SIGKILL after 5 more seconds, and 143 is SIGTERM.
  if [[ $EXIT_CODE -eq 124 ]] || [[ $EXIT_CODE -eq 137 ]] || [[ $EXIT_CODE -eq 143 ]]; then
    echo "TIMEOUT: $basename was stopped (exit $EXIT_CODE): nvim did not exit within $FILE_TIMEOUT"
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

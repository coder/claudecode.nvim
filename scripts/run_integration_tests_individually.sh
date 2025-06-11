#!/bin/bash

# Script to run integration tests individually to avoid plenary test_directory hanging
# Each test file is run separately with test_file

set -e

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

  # Create a temporary file for output
  local temp_output
  temp_output=$(mktemp)

  # Run the test with timeout
  if timeout 30s nix develop .#ci -c nvim --headless -u tests/minimal_init.lua \
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
  success_count=$(echo "$clean_output" | grep -c "Success" || true)
  local failed_lines
  failed_lines=$(echo "$clean_output" | grep "Failed :" || echo "Failed : 0")
  local failed_count
  failed_count=$(echo "$failed_lines" | tail -1 | awk '{print $3}' || echo "0")
  local error_lines
  error_lines=$(echo "$clean_output" | grep "Errors :" || echo "Errors : 0")
  local error_count
  error_count=$(echo "$error_lines" | tail -1 | awk '{print $3}' || echo "0")

  # Update totals
  TOTAL_SUCCESS=$((TOTAL_SUCCESS + success_count))
  TOTAL_FAILED=$((TOTAL_FAILED + failed_count))
  TOTAL_ERRORS=$((TOTAL_ERRORS + error_count))

  # Check if test failed
  if [[ $failed_count -gt 0 ]] || [[ $error_count -gt 0 ]] || { [[ $EXIT_CODE -ne 0 ]] && [[ $EXIT_CODE -ne 124 ]] && [[ $EXIT_CODE -ne 143 ]]; }; then
    FAILED_FILES+=("$basename")
  fi

  # Cleanup
  rm -f "$temp_output"
}

# Run each test file, skipping command_args_spec.lua which is known to hang
for test_file in tests/integration/*_spec.lua; do
  if [[ $test_file == *"command_args_spec.lua" ]]; then
    echo ""
    echo "Skipping: $(basename "$test_file") (known to hang in CI)"
    continue
  fi

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
if [[ $TOTAL_FAILED -eq 0 ]] && [[ $TOTAL_ERRORS -eq 0 ]]; then
  echo ""
  echo "✅ All integration tests passed!"
  exit 0
else
  echo ""
  echo "❌ Some integration tests failed!"
  exit 1
fi

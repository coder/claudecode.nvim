#!/usr/bin/env bash
#
# Claude Code Hook: Format Files
# Triggers after Claude edits/writes files and runs nix fmt
#
# Environment variables provided by Claude Code:
# - CLAUDE_PROJECT_DIR: Path to the project directory
# - CLAUDE_TOOL_NAME: Name of the tool that was executed
# - CLAUDE_TOOL_ARGS: JSON string containing tool arguments

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log function
log() {
  echo -e "[$(date '+%H:%M:%S')] $1" >&2
}

# Parse tool arguments to get the file path
get_file_path() {
  # Read hook input from stdin
  local hook_input
  if [ -t 0 ]; then
    # No stdin input available
    log "DEBUG: No stdin input available"
    return
  fi

  hook_input=$(cat)
  log "DEBUG: Hook input = $hook_input"

  # Try to extract file_path from tool_input
  local file_path
  file_path=$(echo "$hook_input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

  if [ -n "$file_path" ]; then
    echo "$file_path"
    return
  fi

  # Try extracting any file path from the input
  local any_file_path
  any_file_path=$(echo "$hook_input" | grep -o '"[^"]*\.[^"]*"' | sed 's/"//g' | head -1)

  if [ -n "$any_file_path" ]; then
    echo "$any_file_path"
    return
  fi

  log "DEBUG: Could not extract file path from hook input"
}

# Main logic
main() {
  log "${YELLOW}Claude Code Hook: File Formatter${NC}"

  # Get the file path from tool arguments
  FILE_PATH=$(get_file_path)

  if [ -z "$FILE_PATH" ]; then
    log "${RED}Error: Could not determine file path from tool arguments${NC}"
    exit 1
  fi

  log "Tool: ${CLAUDE_TOOL_NAME:-unknown}, File: $FILE_PATH"

  # Check if file exists
  if [ ! -f "$FILE_PATH" ]; then
    log "${RED}Error: File does not exist: $FILE_PATH${NC}"
    exit 1
  fi

  log "${YELLOW}Formatting file with nix fmt...${NC}"

  # Change to project directory
  cd "${CLAUDE_PROJECT_DIR}"

  # Run nix fmt on the file
  if nix fmt "$FILE_PATH" 2>/dev/null; then
    log "${GREEN}✓ Successfully formatted: $FILE_PATH${NC}"
    exit 0
  else
    EXIT_CODE=$?
    log "${RED}✗ nix fmt failed with exit code $EXIT_CODE${NC}"
    log "${RED}This indicates the file has formatting issues that need manual attention${NC}"

    # Don't fail the hook - just warn about formatting issues
    # This allows Claude's operation to continue while alerting about format problems
    log "${YELLOW}Continuing with Claude's operation, but please fix formatting issues${NC}"
    exit 0
  fi
}

# Run main function
main "$@"

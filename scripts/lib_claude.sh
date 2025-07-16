#!/usr/bin/env bash
# lib_claude.sh - Common functions for Claude Code MCP testing and interaction
# This library provides reusable functions for interacting with Claude Code's WebSocket API

# Configuration
if [ -n "$CLAUDE_CONFIG_DIR" ]; then
  export CLAUDE_LOCKFILE_DIR="$CLAUDE_CONFIG_DIR/ide"
else
  export CLAUDE_LOCKFILE_DIR="$HOME/.claude/ide"
fi
export CLAUDE_LOG_DIR="mcp_test_logs" # Default log directory
export CLAUDE_WS_TIMEOUT=10           # Default timeout in seconds

# Find the Claude Code lock file and extract the port
# Returns the port number on success, or empty string on failure
# Usage: PORT=$(find_claude_lockfile)
# Find the Claude lockfile and extract the port
find_claude_lockfile() {
  # Get all .lock files
  lock_files=$(find "$CLAUDE_LOCKFILE_DIR" -name "*.lock" 2>/dev/null || echo "")

  if [ -z "$lock_files" ]; then
    echo "No Claude lockfiles found. Is the VSCode extension running?" >&2
    return 1
  fi

  # Process each lock file
  newest_file=""
  newest_time=0

  for file in $lock_files; do
    # Get file modification time using stat
    file_time=$(stat -c "%Y" "$file" 2>/dev/null)

    # Update if this is newer
    if [[ -n $file_time ]] && [[ $file_time -gt $newest_time ]]; then
      newest_time=$file_time
      newest_file=$file
    fi
  done

  if [ -n "$newest_file" ]; then
    # Extract port from filename
    port=$(basename "$newest_file" .lock)
    echo "$port"
    return 0
  else
    echo "No valid lock files found" >&2
    return 1
  fi
}

# Get the WebSocket URL for Claude Code
# Usage: WS_URL=$(get_claude_ws_url)
get_claude_ws_url() {
  local port
  port=$(find_claude_lockfile)

  if [[ ! $port =~ ^[0-9]+$ ]]; then
    echo >&2 "Error: Invalid port number: '$port'"
    echo >&2 "Is Claude Code running?"
    return 1
  fi

  echo "ws://localhost:$port"
}

# Get the authentication token from a Claude Code lock file
# Usage: AUTH_TOKEN=$(get_claude_auth_token "$PORT")
get_claude_auth_token() {
  local port="$1"

  if [[ -z $port ]]; then
    echo >&2 "Error: Port number required"
    return 1
  fi

  local lock_file="$CLAUDE_LOCKFILE_DIR/$port.lock"

  if [[ ! -f $lock_file ]]; then
    echo >&2 "Error: Lock file not found: $lock_file"
    return 1
  fi

  # Extract authToken from JSON using jq if available, otherwise basic parsing
  if command -v jq >/dev/null 2>&1; then
    local auth_token
    auth_token=$(jq -r '.authToken // empty' "$lock_file" 2>/dev/null)

    if [[ -z $auth_token ]]; then
      echo >&2 "Error: No authToken found in lock file"
      return 1
    fi

    echo "$auth_token"
  else
    # Fallback parsing without jq
    local auth_token
    auth_token=$(grep -o '"authToken"[[:space:]]*:[[:space:]]*"[^"]*"' "$lock_file" | sed 's/.*"authToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    if [[ -z $auth_token ]]; then
      echo >&2 "Error: No authToken found in lock file (install jq for better JSON parsing)"
      return 1
    fi

    echo "$auth_token"
  fi
}

# Create a JSON-RPC request message (with ID)
# Usage: MSG=$(create_message "method_name" '{"param":"value"}' "request-id")
create_message() {
  local method="$1"
  local params="$2"
  local id="$3"

  cat <<EOF
{
  "jsonrpc": "2.0",
  "id": "$id",
  "method": "$method",
  "params": $params
}
EOF
}

# Create a JSON-RPC notification message (no ID)
# Usage: MSG=$(create_notification "method_name" '{"param":"value"}')
create_notification() {
  local method="$1"
  local params="$2"

  if [ -z "$params" ]; then
    cat <<EOF
{
  "jsonrpc": "2.0",
  "method": "$method"
}
EOF
  else
    cat <<EOF
{
  "jsonrpc": "2.0",
  "method": "$method",
  "params": $params
}
EOF
  fi
}

# Create an MCP initialization message
# Usage: MSG=$(create_init_message "client-id")
create_init_message() {
  local id="${1:-init-1}"

  create_message "initialize" '{
    "protocolVersion": "2025-03-26",
    "capabilities": {
      "roots": {
        "listChanged": true
      },
      "sampling": {}
    },
    "clientInfo": {
      "name": "ClaudeCodeNvim",
      "version": "0.2.0"
    }
  }' "$id"
}

# Send a message to the Claude Code WebSocket and get the response
# Usage: RESPONSE=$(send_claude_message "$MESSAGE" "$WS_URL" "$AUTH_TOKEN")
send_claude_message() {
  local message="$1"
  local ws_url="${2:-}"
  local auth_token="${3:-}"
  local timeout="${CLAUDE_WS_TIMEOUT:-5}"

  # Auto-detect WS URL if not provided
  if [ -z "$ws_url" ]; then
    ws_url=$(get_claude_ws_url)
  fi

  # Auto-detect auth token if not provided
  if [ -z "$auth_token" ]; then
    local port
    port=$(find_claude_lockfile)
    if [[ $port =~ ^[0-9]+$ ]]; then
      auth_token=$(get_claude_auth_token "$port")
    fi
  fi

  # Build websocat command with optional auth header
  local websocat_cmd="websocat --protocol permessage-deflate --text"

  if [ -n "$auth_token" ]; then
    websocat_cmd="$websocat_cmd --header 'x-claude-code-ide-authorization: $auth_token'"
  fi

  websocat_cmd="$websocat_cmd '$ws_url' --no-close"

  # Send message and get response with timeout
  timeout "$timeout" bash -c "echo -n '$message' | $websocat_cmd" 2>/dev/null ||
    echo '{"error":{"code":-32000,"message":"Timeout waiting for response"}}'
}

# Initialize a log directory for test output
# Usage: init_log_dir "test_name"
init_log_dir() {
  local test_name="${1:-test}"
  local log_dir="${CLAUDE_LOG_DIR}"

  mkdir -p "$log_dir"
  local log_file="$log_dir/${test_name}.jsonl"
  local pretty_log="$log_dir/${test_name}_pretty.txt"

  # Clear previous log files
  : >"$log_file"
  : >"$pretty_log"

  echo "$log_file:$pretty_log"
}

# Log a message and response to log files
# Usage: log_message_and_response "$MSG" "$RESPONSE" "$LOG_FILE" "$PRETTY_LOG" "Request description"
log_message_and_response() {
  local message="$1"
  local response="$2"
  local log_file="$3"
  local pretty_log="$4"
  local description="${5:-Message}"

  # Log the raw request and response
  echo "$message" >>"$log_file"
  echo "$response" >>"$log_file"

  # Log pretty-formatted request and response
  echo -e "\n--- $description Request ---" >>"$pretty_log"
  echo "$message" | jq '.' >>"$pretty_log" 2>/dev/null || echo "$message" >>"$pretty_log"
  echo -e "\n--- $description Response ---" >>"$pretty_log"
  echo "$response" | jq '.' >>"$pretty_log" 2>/dev/null || echo "Invalid JSON: $response" >>"$pretty_log"
}

# Test if Claude Code is running by checking for a valid WebSocket port
# Usage: if claude_is_running; then echo "Claude is running!"; fi
claude_is_running() {
  local port
  port=$(find_claude_lockfile 2>/dev/null)
  [[ $port =~ ^[0-9]+$ ]]
}

# Simple tools/list call to check if connection is working
# Usage: TOOLS=$(list_claude_tools)
list_claude_tools() {
  local ws_url
  ws_url=$(get_claude_ws_url)

  local msg
  msg=$(create_message "tools/list" "{}" "tools-list")

  local response
  response=$(send_claude_message "$msg" "$ws_url")

  echo "$response"
}

# Get the current selection in the editor
# Usage: SELECTION=$(get_current_selection)
get_current_selection() {
  local ws_url
  ws_url=$(get_claude_ws_url)

  local msg
  msg=$(create_message "tools/call" '{"name":"getCurrentSelection","arguments":{}}' "get-selection")

  local response
  response=$(send_claude_message "$msg" "$ws_url")

  echo "$response"
}

# Open a file in the editor
# Usage: open_file "/path/to/file.txt"
open_file() {
  local file_path="$1"

  local ws_url
  ws_url=$(get_claude_ws_url)

  # Ensure absolute path
  if [[ $file_path != /* ]]; then
    file_path="$(realpath "$file_path")"
  fi

  local msg
  msg=$(create_message "tools/call" "{\"name\":\"openFile\",\"arguments\":{\"filePath\":\"$file_path\",\"startText\":\"\",\"endText\":\"\"}}" "open-file")

  send_claude_message "$msg" "$ws_url" >/dev/null
  return $?
}

# Check if a command exists
# Usage: if command_exists "websocat"; then echo "websocat is installed"; fi
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check if required tools are installed
# Usage: check_required_tools
check_required_tools() {
  local missing=0

  if ! command_exists "websocat"; then
    echo >&2 "Error: websocat is not installed. Please install it to use this library."
    echo >&2 "  - On macOS: brew install websocat"
    echo >&2 "  - On Linux: cargo install websocat"
    missing=1
  fi

  if ! command_exists "jq"; then
    echo >&2 "Error: jq is not installed. Please install it to use this library."
    echo >&2 "  - On macOS: brew install jq"
    echo >&2 "  - On Linux: apt-get install jq or yum install jq"
    missing=1
  fi

  return $missing
}

# Perform a complete initialization sequence with Claude Code
# Usage: RESULT=$(initialize_claude_session)
initialize_claude_session() {
  local ws_url
  ws_url=$(get_claude_ws_url)

  # Send initialize request
  local init_msg
  init_msg=$(create_init_message "init-1")

  local init_response
  init_response=$(send_claude_message "$init_msg" "$ws_url")

  # Send initialized notification
  local init_notification
  init_notification=$(create_notification "initialized" "")
  send_claude_message "$init_notification" "$ws_url" >/dev/null

  # Return the initialization response
  echo "$init_response"
}

# Check environment and required tools when the library is sourced
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  # Running as a script - show usage info
  echo "Claude Code Library - Common functions for interacting with Claude Code"
  echo
  echo "This script is meant to be sourced in other scripts:"
  echo "  source ${BASH_SOURCE[0]}"
  echo
  echo "Example usage in interactive shell:"
  echo '  PORT=$(find_claude_lockfile)'
  echo '  WS_URL=$(get_claude_ws_url)'
  echo '  TOOLS=$(list_claude_tools)'
  echo
else
  # Running as a sourced library - check required tools
  check_required_tools
fi

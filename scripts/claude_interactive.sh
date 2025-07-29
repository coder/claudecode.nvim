#!/usr/bin/env bash
# claude_interactive.sh - Interactive script for working with Claude Code WebSocket API
# This script provides a menu-driven interface for common operations

# Source the libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib_claude.sh
source "$SCRIPT_DIR/lib_claude.sh"
# shellcheck source=./lib_ws_persistent.sh
source "$SCRIPT_DIR/lib_ws_persistent.sh"

# Configuration
export CLAUDE_LOG_DIR="mcp_interactive_logs"
mkdir -p "$CLAUDE_LOG_DIR"
CONN_ID="claude_interactive"

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if Claude Code is running
if ! claude_is_running; then
  echo -e "${RED}Claude Code doesn't appear to be running.${NC}"
  echo "Please start Claude Code and try again."
  exit 1
fi

# Get WebSocket URL and authentication info
WS_URL=$(get_claude_ws_url)
PORT=$(find_claude_lockfile)
AUTH_TOKEN=$(get_claude_auth_token "$PORT")

# Initialize WebSocket connection
echo -e "${BLUE}Initializing WebSocket connection to ${WS_URL}...${NC}"
if ! ws_connect "$WS_URL" "$CONN_ID" "$AUTH_TOKEN"; then
  echo -e "${RED}Failed to establish connection.${NC}"
  exit 1
fi

# Send initial connection handshake
echo -e "${BLUE}Sending initial handshake...${NC}"
# Format JSON to a single line for proper WebSocket transmission
HANDSHAKE_PARAMS=$(ws_format_json '{
  "protocolVersion": "2024-11-05",
  "capabilities": {
    "tools": {}
  },
  "clientInfo": {
    "name": "claude-nvim-client",
    "version": "0.2.0"
  }
}')
ws_notify "mcp.connect" "$HANDSHAKE_PARAMS" "$CONN_ID"

# Display header
clear
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}       Claude Code Interactive CLI      ${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Connected to WebSocket:${NC} $WS_URL"
echo -e "${GREEN}Using connection:${NC} $CONN_ID"
echo

# Function to display menu
show_menu() {
  echo -e "${YELLOW}Available Commands:${NC}"
  echo "  1) Get current selection"
  echo "  2) List available tools"
  echo "  3) Open a file"
  echo "  4) Send custom JSON-RPC message"
  echo "  5) Initialize session"
  echo "  6) Show connection info"
  echo "  7) Listen for messages"
  echo "  8) Reconnect WebSocket"
  echo "  9) Exit"
  echo
  echo -n "Enter your choice [1-9]: "
}

# Function to handle getting current selection
handle_get_selection() {
  echo -e "${BLUE}Getting current selection...${NC}"

  response=$(ws_rpc_request "tools/call" '{"name":"getCurrentSelection","arguments":{}}' "selection-$(date +%s)" "$CONN_ID")

  if echo "$response" | grep -q '"error"'; then
    echo -e "${RED}Error:${NC}"
    echo "$response" | jq .error
  else
    echo -e "${GREEN}Selection information:${NC}"
    echo "$response" | jq .

    # Extract selection text if available - handle both direct response and nested content
    selection_text=$(echo "$response" | jq -r '.result.text // .result.content[0].text // "No text selected"')
    if [ "$selection_text" != "No text selected" ] && [ "$selection_text" != "null" ]; then
      echo -e "${YELLOW}Selected text:${NC}"
      echo "$selection_text"
    fi
  fi
}

# Function to handle listing tools
handle_list_tools() {
  echo -e "${BLUE}Listing available tools...${NC}"

  response=$(ws_rpc_request "tools/list" "{}" "tools-$(date +%s)" "$CONN_ID")

  if echo "$response" | grep -q '"error"'; then
    echo -e "${RED}Error:${NC}"
    echo "$response" | jq .error
  else
    echo -e "${GREEN}Available tools:${NC}"
    echo "$response" | jq -r '.result.tools[] | .name' 2>/dev/null | sort | while read -r tool; do
      echo "  - $tool"
    done

    echo
    echo -e "${YELLOW}Total tools:${NC} $(echo "$response" | jq '.result.tools | length' 2>/dev/null || echo "unknown")"
  fi
}

# Function to handle opening a file
handle_open_file() {
  echo -n "Enter file path (absolute or relative): "
  read -r file_path

  if [ -z "$file_path" ]; then
    echo -e "${RED}File path cannot be empty.${NC}"
    return
  fi

  # Convert to absolute path if relative
  if [[ $file_path != /* ]]; then
    file_path="$(realpath "$file_path" 2>/dev/null)"
    if ! realpath "$file_path" &>/dev/null; then
      echo -e "${RED}Invalid file path: $file_path${NC}"
      return
    fi
  fi

  if [ ! -f "$file_path" ]; then
    echo -e "${RED}File does not exist: $file_path${NC}"
    return
  fi

  echo -e "${BLUE}Opening file:${NC} $file_path"

  # Format the JSON parameters to a single line
  PARAMS=$(ws_format_json "{\"name\":\"openFile\",\"arguments\":{\"filePath\":\"$file_path\",\"startText\":\"\",\"endText\":\"\"}}")
  response=$(ws_rpc_request "tools/call" "$PARAMS" "open-file-$(date +%s)" "$CONN_ID")

  if echo "$response" | grep -q '"error"'; then
    echo -e "${RED}Error:${NC}"
    echo "$response" | jq .error
  else
    echo -e "${GREEN}File opened successfully.${NC}"
  fi
}

# Function to handle sending a custom message
handle_custom_message() {
  echo "Enter method name (e.g., tools/list, getCurrentSelection):"
  read -r method

  if [ -z "$method" ]; then
    echo -e "${RED}Method name cannot be empty.${NC}"
    return
  fi

  echo "Enter parameters as JSON (default: {}):"
  read -r params

  # Use empty object if no params provided
  if [ -z "$params" ]; then
    params="{}"
  fi

  # Validate JSON
  if ! echo "$params" | jq . >/dev/null 2>&1; then
    echo -e "${RED}Invalid JSON parameters.${NC}"
    return
  fi

  # Format params to single line JSON
  params=$(ws_format_json "$params")

  echo "Enter request ID (default: custom-$(date +%s)):"
  read -r id

  # Use default ID if none provided
  if [ -z "$id" ]; then
    id="custom-$(date +%s)"
  fi

  echo -e "${BLUE}Sending custom message:${NC}"

  # Create message in proper single-line format
  request=$(ws_create_message "$method" "$params" "$id")
  echo "$request" | jq .

  echo -e "${BLUE}Response:${NC}"
  response=$(ws_request "$request" "$CONN_ID" 5)
  echo "$response" | jq .
}

# Function to handle initializing a session
handle_initialize() {
  echo -e "${BLUE}Initializing Claude session...${NC}"

  # Format init params to single line
  INIT_PARAMS=$(ws_format_json '{
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
  }')

  response=$(ws_rpc_request "initialize" "$INIT_PARAMS" "init-$(date +%s)" "$CONN_ID")

  if echo "$response" | grep -q '"error"'; then
    echo -e "${RED}Initialization error:${NC}"
    echo "$response" | jq .error
  else
    echo -e "${GREEN}Session initialized successfully:${NC}"
    echo "$response" | jq .

    # Send initialized notification
    ws_notify "initialized" "{}" "$CONN_ID"
    echo -e "${GREEN}Sent initialized notification${NC}"

    # Extract protocol version
    protocol=$(echo "$response" | jq -r '.result.protocolVersion // "unknown"')
    echo -e "${YELLOW}Protocol version:${NC} $protocol"
  fi
}

# Function to display connection info
handle_connection_info() {
  echo -e "${BLUE}Connection Information:${NC}"
  echo -e "${YELLOW}WebSocket URL:${NC} $WS_URL"
  echo -e "${YELLOW}Port:${NC} $PORT"
  echo -e "${YELLOW}Lock file:${NC} $CLAUDE_LOCKFILE_DIR/$PORT.lock"

  if [ -f "$CLAUDE_LOCKFILE_DIR/$PORT.lock" ]; then
    echo -e "${YELLOW}Lock file contents:${NC}"
    cat "$CLAUDE_LOCKFILE_DIR/$PORT.lock"
  fi

  # Display WebSocket connection info
  if ws_is_connected "$CONN_ID"; then
    echo -e "${YELLOW}WebSocket connection status:${NC} ${GREEN}Active${NC}"
  else
    echo -e "${YELLOW}WebSocket connection status:${NC} ${RED}Inactive${NC}"
  fi
}

# Callback function for message listener
process_interactive_message() {
  local message="$1"
  local count="$2"

  echo -e "${GREEN}Message #$count received:${NC}"
  echo "$message" | jq .
  echo
}

# Function to listen for messages
handle_listen() {
  echo -e "${BLUE}Listening for WebSocket messages...${NC}"
  echo "Press Ctrl+C to stop listening."

  # Start the listener with our callback function
  ws_start_listener "$CONN_ID" process_interactive_message

  # We'll use a simple loop to keep this function running until Ctrl+C
  while true; do
    sleep 1
  done

  # The ws_stop_listener will be called by the trap in the main script
}

# Function to reconnect WebSocket
handle_reconnect() {
  echo -e "${BLUE}Reconnecting WebSocket...${NC}"

  # Disconnect and reconnect
  ws_disconnect "$CONN_ID"
  if ws_connect "$WS_URL" "$CONN_ID"; then
    echo -e "${GREEN}Reconnection successful.${NC}"

    # Send handshake again
    HANDSHAKE_PARAMS=$(ws_format_json '{
      "protocolVersion": "2024-11-05",
      "capabilities": {
        "tools": {}
      },
      "clientInfo": {
        "name": "claude-nvim-client",
        "version": "0.2.0"
      }
    }')
    ws_notify "mcp.connect" "$HANDSHAKE_PARAMS" "$CONN_ID"
  else
    echo -e "${RED}Reconnection failed.${NC}"
  fi
}

# Main loop
while true; do
  show_menu
  read -r choice
  echo

  case $choice in
  1) handle_get_selection ;;
  2) handle_list_tools ;;
  3) handle_open_file ;;
  4) handle_custom_message ;;
  5) handle_initialize ;;
  6) handle_connection_info ;;
  7)
    # Handle Ctrl+C gracefully for the listen function
    trap 'echo -e "\n${YELLOW}Stopped listening.${NC}"; ws_stop_listener "$CONN_ID"; trap - INT; break' INT
    handle_listen
    trap - INT
    ;;
  8) handle_reconnect ;;
  9)
    echo "Cleaning up connections and exiting..."
    ws_stop_listener "$CONN_ID" 2>/dev/null # Stop any listener if active
    ws_disconnect "$CONN_ID"
    exit 0
    ;;
  *) echo -e "${RED}Invalid choice. Please try again.${NC}" ;;
  esac

  echo
  echo -n "Press Enter to continue..."
  read -r
  clear
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}       Claude Code Interactive CLI      ${NC}"
  echo -e "${BLUE}========================================${NC}"
  echo -e "${GREEN}Connected to WebSocket:${NC} $WS_URL"
  echo -e "${GREEN}Using connection:${NC} $CONN_ID"
  echo
done

#!/usr/bin/env bash
# lib_ws_persistent.sh - Library for persistent WebSocket connections
# A simpler, more reliable implementation

# Configuration
WS_LOG_DIR="${TMPDIR:-/tmp}/ws_logs"
mkdir -p "$WS_LOG_DIR"

# Store active connections
declare -A WS_CONNECTIONS
declare -A WS_REQUEST_FILES

# Start a persistent WebSocket connection
# ws_connect URL [CONN_ID] [AUTH_TOKEN]
ws_connect() {
  local url="$1"
  local conn_id="${2:-default}"
  local auth_token="${3:-}"

  # Cleanup any existing connection with this ID
  ws_disconnect "$conn_id"

  # Create connection log directory
  local log_dir="$WS_LOG_DIR/$conn_id"
  mkdir -p "$log_dir"

  # Files for this connection
  local pid_file="$log_dir/pid"
  local log_file="$log_dir/log.txt"
  local request_file="$log_dir/request.json"
  local response_file="$log_dir/response.json"

  # Store request file path for later use
  WS_REQUEST_FILES[$conn_id]="$request_file"

  # Create empty files
  : >"$request_file"
  : >"$response_file"

  # This uses a simpler approach - websocat runs in the background and:
  # 1. Reads JSON requests from request_file
  # 2. Writes all server responses to response_file
  (
    # Note: The -E flag makes websocat exit when the file is closed
    if [ -n "$auth_token" ]; then
      # Use websocat with auth header - avoid eval by constructing command safely
      tail -f "$request_file" | websocat -t --header "x-claude-code-ide-authorization: $auth_token" "$url" | tee -a "$response_file" >"$log_file" &
    else
      # Use websocat without auth header
      tail -f "$request_file" | websocat -t "$url" | tee -a "$response_file" >"$log_file" &
    fi

    # Save PID
    echo $! >"$pid_file"

    # Wait for process to finish
    wait
  ) &

  # Save the background process group ID
  local pgid=$!
  WS_CONNECTIONS[$conn_id]="$pgid|$log_dir"

  # Wait briefly for connection to establish
  sleep 0.5

  # Check if process is still running
  if ws_is_connected "$conn_id"; then
    return 0
  else
    return 1
  fi
}

# Check if a connection is active
# ws_is_connected [CONN_ID]
ws_is_connected() {
  local conn_id="${1:-default}"

  # Check if we have this connection
  if [[ -z ${WS_CONNECTIONS[$conn_id]} ]]; then
    return 1
  fi

  # Get connection info
  local info="${WS_CONNECTIONS[$conn_id]}"
  local pgid
  pgid=$(echo "$info" | cut -d'|' -f1)
  local log_dir
  log_dir=$(echo "$info" | cut -d'|' -f2)
  local pid_file="$log_dir/pid"

  # Check if process is running
  if [[ -f $pid_file ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Disconnect and clean up a connection
# ws_disconnect [CONN_ID]
ws_disconnect() {
  local conn_id="${1:-default}"

  # Check if we have this connection
  if [[ -z ${WS_CONNECTIONS[$conn_id]} ]]; then
    return 0
  fi

  # Get connection info
  local info="${WS_CONNECTIONS[$conn_id]}"
  local pgid
  pgid=$(echo "$info" | cut -d'|' -f1)
  local log_dir
  log_dir=$(echo "$info" | cut -d'|' -f2)
  local pid_file="$log_dir/pid"

  # Kill the process group
  if [[ -f $pid_file ]]; then
    local pid
    pid=$(cat "$pid_file")
    kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
  fi

  # Remove from tracking
  unset "WS_CONNECTIONS[$conn_id]"
  unset "WS_REQUEST_FILES[$conn_id]"

  return 0
}

# Send a message and get the response
# ws_request JSON_MESSAGE [CONN_ID] [TIMEOUT]
ws_request() {
  local message="$1"
  local conn_id="${2:-default}"
  local timeout="${3:-10}"

  # Make sure we're connected
  if ! ws_is_connected "$conn_id"; then
    echo >&2 "Error: Not connected with ID $conn_id"
    return 1
  fi

  # Get the request file
  local request_file="${WS_REQUEST_FILES[$conn_id]}"

  # Get connection info
  local info="${WS_CONNECTIONS[$conn_id]}"
  local log_dir
  log_dir=$(echo "$info" | cut -d'|' -f2)
  local response_file="$log_dir/response.json"
  local temp_response_file="${log_dir}/temp_response.$$"

  # Extract message ID for matching response
  local id
  id=$(echo "$message" | jq -r '.id // empty' 2>/dev/null)

  if [[ -z $id ]]; then
    echo >&2 "Error: Message has no ID field"
    return 1
  fi

  # Save current position in response file
  local start_pos
  start_pos=$(wc -c <"$response_file")

  # Send the message
  echo "$message" >>"$request_file"

  # Create empty temp file
  true >"$temp_response_file"

  # Wait for response with matching ID
  local end_time=$(($(date +%s) + timeout))
  local response_found=false

  # Log request for debugging
  echo "Request ID: $id - $(date +%H:%M:%S)" >>"$log_dir/debug.log"
  echo "$message" >>"$log_dir/debug.log"

  while [[ $(date +%s) -lt $end_time ]] && [[ $response_found == "false" ]]; do
    # Check for new data in the response file
    if [[ -s $response_file && $(wc -c <"$response_file") -gt $start_pos ]]; then
      # Extract new responses
      local new_data
      new_data=$(tail -c +$((start_pos + 1)) "$response_file")

      # Write to temp file first to allow process substitution to work correctly
      echo "$new_data" >"$temp_response_file"

      # Process each line and check for matching ID
      while IFS= read -r line; do
        if [[ -z $line ]]; then
          continue
        fi

        # Log response for debugging
        echo "Checking response: $(echo "$line" | jq -r '.id // "no-id"')" >>"$log_dir/debug.log"

        # Parse response ID
        local response_id
        response_id=$(echo "$line" | jq -r '.id // empty' 2>/dev/null)

        if [[ $response_id == "$id" ]]; then
          # Found matching response - need to echo outside the loop
          echo "$line" >"$temp_response_file.found"
          response_found=true
          break
        fi
      done <"$temp_response_file"

      # Update position for next check
      start_pos=$(wc -c <"$response_file")
    fi

    # Short sleep to avoid CPU spinning
    sleep 0.1
  done

  # Check if we found a response
  if [[ -f "$temp_response_file.found" ]]; then
    cat "$temp_response_file.found"
    rm -f "$temp_response_file" "$temp_response_file.found"
    return 0
  else
    echo >&2 "Error: Timeout waiting for response to message with ID $id"
    # Return the most recent message as a fallback - it might be what we're looking for
    if [[ -s $temp_response_file ]]; then
      tail -1 "$temp_response_file"
    else
      echo "{\"jsonrpc\":\"2.0\",\"id\":\"$id\",\"error\":{\"code\":-32000,\"message\":\"Timeout waiting for response\"}}"
    fi
    rm -f "$temp_response_file" "$temp_response_file.found"
    return 0 # Still return success to allow processing the fallback response
  fi
}

# Send a notification (no response expected)
# ws_notify METHOD PARAMS [CONN_ID]
ws_notify() {
  local method="$1"
  local params="$2"
  local conn_id="${3:-default}"

  # Format JSON-RPC notification on a single line
  local notification="{ \"jsonrpc\": \"2.0\", \"method\": \"$method\", \"params\": $params }"

  # Make sure we're connected
  if ! ws_is_connected "$conn_id"; then
    echo >&2 "Error: Not connected with ID $conn_id"
    return 1
  fi

  # Get the request file
  local request_file="${WS_REQUEST_FILES[$conn_id]}"

  # Send the notification
  echo "$notification" >>"$request_file"
  return 0
}

# Send a JSON-RPC request and wait for response
# ws_rpc_request METHOD PARAMS [ID] [CONN_ID] [TIMEOUT]
ws_rpc_request() {
  local method="$1"
  local params="$2"
  local id="${3:-req-$(date +%s)}"
  local conn_id="${4:-default}"
  local timeout="${5:-10}"

  # Special handling for legacy mcp.connect and current initialize
  if [[ $method == "mcp.connect" ]]; then
    # For backward compatibility, support the old method
    # Send the message without waiting for response
    ws_notify "$method" "$params" "$conn_id"
    # Return fake success response
    echo "{\"jsonrpc\":\"2.0\",\"id\":\"$id\",\"result\":{\"message\":\"Connected\"}}"
    return 0
  fi

  # No special handling needed for initialize - it's a proper JSON-RPC request that expects a response

  # Format JSON-RPC request on a single line
  local request="{ \"jsonrpc\": \"2.0\", \"id\": \"$id\", \"method\": \"$method\", \"params\": $params }"

  # Send request and wait for response
  ws_request "$request" "$conn_id" "$timeout"
}

# Create a JSON-RPC message (for use with ws_request)
# ws_create_message METHOD PARAMS [ID]
ws_create_message() {
  local method="$1"
  local params="$2"
  local id="${3:-msg-$(date +%s)}"

  # Output a single-line JSON message
  echo "{ \"jsonrpc\": \"2.0\", \"id\": \"$id\", \"method\": \"$method\", \"params\": $params }"
}

# Format JSON object to a single line (useful for preparing params)
# ws_format_json "JSON_OBJECT"
ws_format_json() {
  local json="$1"
  # Use jq to normalize and compact the JSON
  echo "$json" | jq -c '.'
}

# Clean up all connections
ws_cleanup_all() {
  for id in "${!WS_CONNECTIONS[@]}"; do
    ws_disconnect "$id"
  done
}

# Set up trap to clean up all connections on exit
ws_setup_trap() {
  trap ws_cleanup_all EXIT INT TERM
}

# Start a message listener in the background
# ws_start_listener CONN_ID CALLBACK_FUNCTION [FILTER_METHOD]
# Example: ws_start_listener "my_conn" process_message "selection_changed"
ws_start_listener() {
  local conn_id="${1:-default}"
  local callback_function="$2"
  local filter_method="${3:-}"

  # Check if connection exists
  if ! ws_is_connected "$conn_id"; then
    echo >&2 "Error: Connection $conn_id not active"
    return 1
  fi

  # Get connection info
  local info="${WS_CONNECTIONS[$conn_id]}"
  local log_dir
  log_dir=$(echo "$info" | cut -d'|' -f2)
  local response_file="$log_dir/response.json"
  local listener_pid_file="$log_dir/listener.pid"

  # Start background process
  (
    # Start position in the response file
    local start_pos
    start_pos=$(wc -c <"$response_file")
    local count=0

    while true; do
      # Check for new data in the response file
      if [[ -s $response_file && $(wc -c <"$response_file") -gt $start_pos ]]; then
        # Extract new responses
        local new_data
        new_data=$(tail -c +$((start_pos + 1)) "$response_file")

        # Process each line
        echo "$new_data" | while IFS= read -r message; do
          if [[ -z $message ]]; then
            continue
          fi

          # If filter method is specified, only process matching messages
          if [[ -z $filter_method ]] || echo "$message" | grep -q "\"method\":\"$filter_method\""; then
            count=$((count + 1))

            # Call the callback function with the message and count
            $callback_function "$message" "$count"
          fi
        done

        # Update position for next check
        start_pos=$(wc -c <"$response_file")
      fi

      sleep 0.5
    done
  ) &

  # Save PID for later cleanup
  echo $! >"$listener_pid_file"

  return 0
}

# Stop a previously started listener
# ws_stop_listener CONN_ID
ws_stop_listener() {
  local conn_id="${1:-default}"

  # Get connection info
  local info="${WS_CONNECTIONS[$conn_id]}"
  if [[ -z $info ]]; then
    return 0
  fi

  local log_dir
  log_dir=$(echo "$info" | cut -d'|' -f2)
  local listener_pid_file="$log_dir/listener.pid"

  if [[ -f $listener_pid_file ]]; then
    local pid
    pid=$(cat "$listener_pid_file")
    kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
    rm -f "$listener_pid_file"
  fi
}

# If script is run directly, show usage
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  echo "WebSocket Persistent Connection Library"
  echo "This script is meant to be sourced by other scripts:"
  echo "  source ${BASH_SOURCE[0]}"
  echo
  echo "Available functions:"
  echo "  ws_connect URL [CONN_ID]                           - Initialize connection"
  echo "  ws_disconnect [CONN_ID]                            - Close connection"
  echo "  ws_is_connected [CONN_ID]                          - Check if connected"
  echo "  ws_request JSON_MESSAGE [CONN_ID] [TIMEOUT]        - Send raw message and get response"
  echo "  ws_notify METHOD PARAMS [CONN_ID]                  - Send notification (no response)"
  echo "  ws_rpc_request METHOD PARAMS [ID] [CONN_ID] [TIMEOUT] - Send request and wait for response"
  echo "  ws_create_message METHOD PARAMS [ID]               - Create JSON-RPC message"
  echo "  ws_format_json JSON_OBJECT                         - Format JSON to single line"
  echo "  ws_start_listener CONN_ID CALLBACK_FUNCTION [FILTER_METHOD] - Start background listener"
  echo "  ws_stop_listener CONN_ID                           - Stop a background listener"
  echo "  ws_cleanup_all                                     - Clean up all connections"
  echo "  ws_setup_trap                                      - Set up cleanup trap"
  echo
  echo "IMPORTANT NOTES:"
  echo "  1. All JSON must be single-line for websocat to work properly"
  echo "  2. Use ws_format_json to ensure your JSON is properly formatted"
  echo "  3. For params, use simple one-liners or compact with jq:"
  echo "     PARAMS=\$(ws_format_json '{\"foo\": \"bar\", \"baz\": 123}')"
  echo
  echo "Example usage:"
  echo '  ws_connect "ws://localhost:8080" "my_conn"'
  echo '  ws_rpc_request "tools/list" "{}" "req-1" "my_conn"'
  echo '  PARAMS=$(ws_format_json "{ \"name\": \"getCurrentSelection\" }")'
  echo '  ws_rpc_request "tools/call" "$PARAMS" "req-2" "my_conn"'
else
  # Set up trap if being sourced
  ws_setup_trap
fi

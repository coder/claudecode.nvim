#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034,SC2154 # helpers run through as_bool; covered_block sets blocks by name
# Model-check the @ mention queue and the clients it sends to against facts read from the code.
# Usage: check.sh [--mutants] [--keep] [--record] | check.sh --hash-only
#   exit 0 pass, 1 rule broken, 2 tool or script error, 3 stale (the covered code
#   changed since the model was last confirmed against it: unverified)
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL=verify-mention-queue MODEL=MentionQueue
source "$here/../../../scripts/tla/check-lib.sh"
tla_init "$@"

MAIN=lua/claudecode/init.lua
CONFIG=lua/claudecode/config.lua
SERVER=lua/claudecode/server/init.lua
TCP=lua/claudecode/server/tcp.lua
CLIENT=lua/claudecode/server/client.lua
COVERED=("$MAIN" "$CONFIG" "$SERVER" "$TCP" "$CLIENT")
SITE_RE='(mention_queue|mention_timer|connection_timer|queue_mention|expire_mentions|schedule_mention_flush|flush_mention_queue|process_mention_queue|ms_until_a_client_is_ready|report_unwritten|is_claude_connected|connected_at|handshake_complete|connection_timeout|connection_wait_delay|at_mentioned|on_open|on_written)'

covered_block is_connected "$MAIN" '^function M\.is_claude_connected\('
covered_block until_ready "$MAIN" '^local function ms_until_a_client_is_ready\('
covered_block start_timer "$MAIN" '^local function start_timer\('
covered_block clear_queue "$MAIN" '^local function clear_mention_queue\('
covered_block expire "$MAIN" '^local function expire_mentions\('
covered_block unwritten "$MAIN" '^local function report_unwritten\('
covered_block flush "$MAIN" '^local function flush_mention_queue\('
covered_block schedule "$MAIN" '^schedule_mention_flush = function\('
covered_block queue_mention "$MAIN" '^local function queue_mention\('
covered_block process_queue "$MAIN" '^function M\.process_mention_queue\('
covered_block send_at_mention "$MAIN" '^function M\.send_at_mention\('
covered_block broadcast_mention "$MAIN" '^function M\._broadcast_at_mention\('
covered_block main_stop "$MAIN" '^function M\.stop\(\)'
covered_block on_open "$SERVER" '^ *on_open = function\(client\)'
covered_block server_broadcast "$SERVER" '^function M\.broadcast\('
covered_block server_status "$SERVER" '^function M\.get_status\('
covered_block new_connection "$TCP" '^function M\._handle_new_connection\('
covered_block tcp_broadcast "$TCP" '^function M\.broadcast\('
covered_block clients_info "$TCP" '^function M\.get_clients_info\('
covered_block write "$CLIENT" '^local function write\('
covered_block process_data "$CLIENT" '^function M\.process_data\('
covered_block send_message "$CLIENT" '^function M\.send_message\('
covered_block client_info "$CLIENT" '^function M\.get_client_info\('

FACTS=(EnqueueArmsDeadline DeadlineReportsError DeadlineRearms DeadlineSparesReady SparedQueueFlushes FlushExpiresOverdue
  QueueKeepsDeadline HandshakeFlushes ConnectedSchedulesFlush FlushWaitsForReady WaitRearmsFlush ReadyNeedsConnected
  ReadyFromHandshake FlushSendsHead FlushChecksDelivery FlushRemovesHead FailedWriteReported RefusedWriteReported
  StopClearsQueue ImmediateWaitsForReady)

# queue_mention appends the mention, starts connection_timer for its deadline when none runs, then schedules a flush.
fact[EnqueueArmsDeadline]=$(as_bool in_order '^ *table\.insert\(queue, \{.*deadline = deadline' \
  '^ *if not M\.state\.connection_timer then$' '^ *start_timer\("connection_timer", [a-z_]+, expire_mentions\)$' \
  '^ *schedule_mention_flush\(debounce_delay\)$' <<<"$queue_mention")
fact[DeadlineReportsError]=$(as_bool in_order '^ *if expired > 0 then$' '^ *if M\.is_claude_connected\(\) then$' \
  '^ *logger\.error\($' '"Send timeout - clearing "' '^ *else$' \
  '^ *logger\.error\("queue", "Connection timeout - clearing "' '^ *table\.remove\(queue, 1\)$' <<<"$expire")
fact[DeadlineRearms]=$(as_bool in_order '^ *if #queue == 0 then$' '^ *clear_mention_queue\(\)$' '^ *else$' \
  '^ *start_timer\("connection_timer", queue\[1\]\.deadline - now, expire_mentions\)$' <<<"$expire")
# While a ready client is connected, the deadline clears nothing: the queue drains to that client.
fact[DeadlineSparesReady]=$(as_bool in_order '^ *if ms_until_a_client_is_ready\(\) == 0 then$' '^ *return$' '^ *end$' \
  '^ *local queue = mention_queue\(\)$' <<<"$expire")
# The spared queue keeps a flush due: the handshake's own flush can come later.
fact[SparedQueueFlushes]=$(as_bool in_order '^ *if ms_until_a_client_is_ready\(\) == 0 then$' \
  '^ *schedule_mention_flush\(inter_message_delay\)$' '^ *return$' <<<"$expire")
# A flush that finds no ready client clears the mentions whose deadline passed while a ready client took the queue.
flush_expires_overdue() {
  in_order '^ *if wait and wait > 0 then$' '^ *expire_mentions\(\)$' '^ *if #mention_queue\(\) > 0 then$' \
    '^ *start_timer\("mention_timer", wait, flush_mention_queue\)$' <<<"$flush" &&
    in_order 'No connected client took queued @ mention' '^ *expire_mentions\(\)$' '^ *return$' <<<"$flush"
}
fact[FlushExpiresOverdue]=$(as_bool flush_expires_overdue)
# Only an empty queue stops the deadline: no handshake, flush or send does. start_timer stops a timer of the same name
# too, so the starts count as well.
queue_keeps_deadline() {
  [[ $(grep -c 'stop_timer("connection_timer")' "$MAIN") == 2 ]] &&
    [[ $(grep -c 'start_timer("connection_timer"' "$MAIN") == 2 ]] &&
    in_order 'stop_timer\("connection_timer"\)' <<<"$clear_queue" &&
    in_order '^ *if #mention_queue\(\) == 0 then$' 'stop_timer\("connection_timer"\)' '^ *elseif ' <<<"$schedule"
}
fact[QueueKeepsDeadline]=$(as_bool queue_keeps_deadline)
# The 101 write callback marks the client connected, then calls on_open. server/tcp.lua passes the server's on_open,
# server/init.lua schedules process_mention_queue(true), and that schedules a flush.
handshake_flushes() {
  in_order 'write\(client, response_from_handshake, function\(err\)$' '^ *client\.state = "connected"$' \
    '^ *on_open\(client\)$' <<<"$process_data" &&
    grep -q 'server\.auth_token, server\.on_open)' <<<"$new_connection" &&
    in_order 'vim\.schedule\(function\(\)$' 'main_module\.process_mention_queue\(true\)' <<<"$on_open" &&
    in_order '^ *if from_new_connection then$' '^ *schedule_mention_flush\(M\.state\.config\.connection_wait_delay\)$' \
      <<<"$process_queue"
}
fact[HandshakeFlushes]=$(as_bool handshake_flushes)
fact[ConnectedSchedulesFlush]=$(as_bool in_order \
  '^ *elseif M\.is_claude_connected\(\) and not M\.state\.mention_timer then$' \
  '^ *start_timer\("mention_timer", delay, flush_mention_queue\)$' <<<"$schedule")
fact[FlushWaitsForReady]=$(as_bool in_order '^ *local wait = ms_until_a_client_is_ready\(\)$' \
  '^ *if wait and wait > 0 then$' '^ *return$' '^ *end$' 'server\.broadcast\("at_mentioned"' <<<"$flush")
fact[WaitRearmsFlush]=$(as_bool in_order '^ *if wait and wait > 0 then$' \
  '^ *start_timer\("mention_timer", wait, flush_mention_queue\)$' '^ *return$' <<<"$flush")
fact[ReadyNeedsConnected]=$(as_bool in_order '^ *for _, info in ipairs\(' \
  '^ *if info\.state == "connected" and info\.handshake_complete == true and info\.connected_at then$' \
  '^ *local left = ' <<<"$until_ready")
# connected_at is the time of the handshake: the 101 write callback sets it, and nothing else does.
ready_from_handshake() {
  grep -qE '^ *local left = math\.max\(0, info\.connected_at \+ M\.state\.config\.connection_wait_delay - vim\.loop\.now\(\)\)$' \
    <<<"$until_ready" &&
    in_order 'write\(client, response_from_handshake, function\(err\)$' '^ *client\.handshake_complete = true$' \
      '^ *client\.connected_at = vim\.loop\.now\(\)$' '^ *on_open\(client\)$' <<<"$process_data" &&
    grep -qE '^ *connected_at = client\.connected_at,$' <<<"$client_info" &&
    [[ $(grep -rE 'connected_at *= *[^=]' lua plugin | grep -cvE 'connected_at = client\.connected_at,$') == 1 ]]
}
fact[ReadyFromHandshake]=$(as_bool ready_from_handshake)
fact[FlushSendsHead]=$(as_bool in_order '^ *local mention = queue\[1\]$' 'server\.broadcast\("at_mentioned"' \
  '^ *table\.remove\(queue, 1\)$' <<<"$flush")
# A flush keeps the head when the broadcast reached no client: server/init.lua returns the count of tcp.lua's
# broadcast, which counts only "connected" clients.
flush_checks_delivery() {
  in_order '^ *if not server\.broadcast\("at_mentioned", params, ' '^ *return$' '^ *end$' \
    '^ *table\.remove\(queue, 1\)$' <<<"$flush" &&
    grep -q 'return tcp_server\.broadcast(M\.state\.server, json_message, on_written) > 0' <<<"$server_broadcast" &&
    in_order '^ *if client\.state == "connected" then$' '^ *sent = sent \+ 1$' '^ *return sent$' <<<"$tcp_broadcast"
}
fact[FlushChecksDelivery]=$(as_bool flush_checks_delivery)
fact[FlushRemovesHead]=$(as_bool in_order 'server\.broadcast\("at_mentioned"' '^ *table\.remove\(queue, 1\)$' \
  '^ *schedule_mention_flush\(inter_message_delay\)$' <<<"$flush")
# A broadcast whose writes all failed shows an error: tcp.lua counts the writes and calls on_written once after the
# last one, and the flush passes report_unwritten, which logs an error when none succeeded.
failed_write_reported() {
  grep -q 'report_unwritten("queue", mention\.file_path)' <<<"$flush" &&
    grep -q 'M\.state\.server\.broadcast("at_mentioned", params, report_unwritten("command", formatted_path))' \
      <<<"$broadcast_mention" &&
    in_order '^ *if written == 0 then$' '^ *logger\.error\(component, ' <<<"$unwritten" &&
    in_order 'if dispatched and not reported and pending == 0 and sent > 0 then$' 'on_written\(written\)' \
      '^ *pending = pending \+ 1$' 'client_manager\.send_message\(client, message, function\(err\)$' \
      '^ *if not err then$' '^ *written = written \+ 1$' '^ *finish\(\)$' '^ *dispatched = true$' '^ *finish\(\)$' \
      <<<"$tcp_broadcast"
}
fact[FailedWriteReported]=$(as_bool failed_write_reported)
# libuv returns nil and the error for a write it refuses at once, and never runs that write's callback.
refused_write_reported() {
  in_order '^ *local queued, err = write\(client, text_frame, callback\)$' '^ *if not queued and err and callback then$' \
    '^ *callback\(err\)$' <<<"$send_message" &&
    in_order '^ *return client\.tcp_handle:write\(data, callback\)$' '^ *return queued, err$' <<<"$write"
}
fact[RefusedWriteReported]=$(as_bool refused_write_reported)
stop_clears_queue() {
  in_order 'M\.state\.server\.stop\(\)' '^ *M\.state\.server = nil$' '^ *clear_mention_queue\(\)$' <<<"$main_stop" &&
    in_order '^ *M\.state\.mention_queue = \{\}$' '^ *stop_timer\("mention_timer"\)$' \
      '^ *stop_timer\("connection_timer"\)$' <<<"$clear_queue"
}
fact[StopClearsQueue]=$(as_bool stop_clears_queue)
# With disable_broadcast_debouncing set and an empty queue, a send while Claude is connected broadcasts at once only
# while ms_until_a_client_is_ready() is 0 or nil. Otherwise it goes to the queue, which waits for a ready client.
fact[ImmediateWaitsForReady]=$(as_bool in_order \
  '^ *if immediate and #mention_queue\(\) == 0 and \(ms_until_a_client_is_ready\(\) or 0\) == 0 then$' \
  'M\.state\.server\.broadcast\("at_mentioned"' '^ *queue_mention\(formatted_path, start_line, end_line\)$' \
  <<<"$broadcast_mention")

RULES=(NoSilentDrop SentInOrder AtMostOnce SentWhenReady NothingAfterStop)
LIVE=(NoStrandedMention ReadyDelivers FlushDelivers)
EXPECT=(
  [EnqueueArmsDeadline]=NoStrandedMention
  [DeadlineReportsError]=NoSilentDrop
  [DeadlineRearms]=NoStrandedMention
  [DeadlineSparesReady]=ReadyDelivers
  [SparedQueueFlushes]=NoStrandedMention
  [FlushExpiresOverdue]=NoStrandedMention
  ["QueueKeepsDeadline+FlushExpiresOverdue"]=NoStrandedMention
  [HandshakeFlushes]=FlushDelivers
  [ConnectedSchedulesFlush]=FlushDelivers
  [FlushWaitsForReady]=SentWhenReady
  [WaitRearmsFlush]=FlushDelivers
  [ReadyNeedsConnected]=SentWhenReady
  [ReadyFromHandshake]=SentWhenReady
  [FlushSendsHead]=SentInOrder
  [FlushChecksDelivery]=NoSilentDrop
  [FlushRemovesHead]=AtMostOnce
  [FailedWriteReported]=NoSilentDrop
  [RefusedWriteReported]=NoSilentDrop
  [StopClearsQueue]=NothingAfterStop
  [ImmediateWaitsForReady]=SentWhenReady
)
# Invariants run with 3 mentions, liveness with 2. FlushDelivers runs with no deadline that passes: in this untimed
# model a deadline can pass at any step, and a spared deadline schedules a flush, so it would hide a flush path that
# leaves a ready Claude waiting for the deadline.
tla_constants() {
  if [[ $2 == live ]]; then echo "  Mentions = 2"; else echo "  Mentions = 3"; fi
  echo "  MaxConnects = 2"
  echo "  MaxStarts = 1"
  if [[ $1 == *FlushDelivers ]]; then echo "  DeadlinesFire = FALSE"; else echo "  DeadlinesFire = TRUE"; fi
}
CONSTRAINT=RecvBound
tla_main

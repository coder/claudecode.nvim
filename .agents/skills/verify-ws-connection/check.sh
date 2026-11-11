#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # check-lib.sh reads these variables; covered_block sets the blocks by name
# Model-check the WebSocket connection lifecycle (server/client.lua, server/tcp.lua) against facts read from the code.
# Usage: check.sh [--mutants] [--keep] [--record] | check.sh --hash-only
#   exit 0 pass, 1 rule broken, 2 tool or script error, 3 stale (the covered code changed since the model was
#   last confirmed against it: unverified)
#   --hash-only compares covered.lock with the code and runs no TLC: exit 0 fresh, 2 error, 3 stale.
#   --record and --hash-only run no TLC, so they do not download it.
# The TLC pin, the option parsing, the TLC runs and the mutant loop live in scripts/tla/check-lib.sh.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL=verify-ws-connection MODEL=WsConnection
source "$here/../../../scripts/tla/check-lib.sh"
tla_init "$@"

CLIENT=lua/claudecode/server/client.lua
TCP=lua/claudecode/server/tcp.lua
HANDSHAKE=lua/claudecode/server/handshake.lua
SERVER=lua/claudecode/server/init.lua
MAIN=lua/claudecode/init.lua
COVERED=("$CLIENT" "$TCP" "$HANDSHAKE" "$SERVER" "$MAIN")
# A site is a line that changes a client's state, writes to or closes its socket, or adds, drops, stops or
# times out a client.
SITE_RE='(close_client|_disconnect_client|_remove_client|stop_server|start_ping_timer|send_ping|drop_client|judge_silence|after_next_poll|tcp_handle:(write|close|read_start)|client\.state = |handshake_complete = |last_pong = |ping_unanswered_since = |server\.clients\[|server\.stop\(\)|ping_timer:)'

covered_block create_client "$CLIENT" '^function M\.create_client\('
covered_block add_data_frame "$CLIENT" '^local function add_data_frame\('
covered_block process_data "$CLIENT" '^function M\.process_data\('
covered_block send_message "$CLIENT" '^function M\.send_message\('
covered_block send_ping "$CLIENT" '^function M\.send_ping\('
covered_block fail_connection "$CLIENT" '^local function fail_connection\('
covered_block close_client "$CLIENT" '^function M\.close_client\('
covered_block abandon_close_frame "$CLIENT" '^function M\.abandon_close_frame\('
covered_block new_connection "$TCP" '^function M\._handle_new_connection\('
covered_block release_socket "$TCP" '^local function release_socket\('
covered_block disconnect "$TCP" '^function M\._disconnect_client\('
covered_block remove_client "$TCP" '^function M\._remove_client\('
covered_block stop_server "$TCP" '^function M\.stop_server\('
covered_block after_next_poll "$TCP" '^local function after_next_poll\('
covered_block drop_client "$TCP" '^local function drop_client\('
covered_block judge_silence "$TCP" '^local function judge_silence\('
covered_block ping_timer "$TCP" '^function M\.start_ping_timer\('
covered_block process_handshake "$HANDSHAKE" '^function M\.process_handshake\('
covered_block extract_request "$HANDSHAKE" '^function M\.extract_http_request\('
covered_block server_start "$SERVER" '^function M\.start\('
covered_block server_stop "$SERVER" '^function M\.stop\(\)'
covered_block main_start "$MAIN" '^function M\.start\('
covered_block main_stop "$MAIN" '^function M\.stop\(\)'

FACTS=(UpgradeInWriteCallback UpgradeRechecksState DispatchGuard PeerCloseMarksClosing
  DisconnectOnce DisconnectClosesSocket UnlistedDisconnectReleases CloseWriteOwnsSocket RejectClosesSocket
  ProtocolReportsAtOnce StopWaitsForCloseWrite KeepaliveReaps JudgesAfterRead ClockFreshAtTick StampKeepsOldestPing
  BytesClearStamp GapSkip WakeClearsStamp)

# The handshake completes in the 101 write callback, after its error check, and nowhere before.
upgrade_in_write_callback() {
  [[ $(grep -c 'client\.handshake_complete = true' <<<"$process_data") == 1 ]] &&
    in_order '^ *if success then$' '^ *client\.state = "upgrading"$' \
      '^ *write\(client, response_from_handshake, function\(err\)$' '^ *if err or not success then$' \
      '^ *client\.handshake_complete = true$' '^ *client\.state = "connected"$' <<<"$process_data"
}
fact[UpgradeInWriteCallback]=$(as_bool upgrade_in_write_callback)
fact[UpgradeRechecksState]=$(as_bool in_order 'write\(client, response_from_handshake, function\(err\)$' \
  '^ *if client\.state ~= "upgrading" or client\.tcp_handle:is_closing\(\) then$' '^ *return$' \
  '^ *client\.handshake_complete = true$' <<<"$process_data")
fact[DispatchGuard]=$(as_bool in_order '^ *vim\.schedule\(function\(\)$' \
  '^ *if client\.state == "connected" and not client\.tcp_handle:is_closing\(\) then$' \
  '^ *on_message\(client, message\)$' <<<"$process_data")
fact[PeerCloseMarksClosing]=$(as_bool in_order 'elseif opcode == frame\.OPCODE\.CLOSE then$' \
  '^ *if client\.state == "connected" then$' '^ *write\(client, close_frame\)$' \
  '^ *client\.state = "closing"$' '^ *on_close\(client, code, reason\)$' <<<"$process_data")
fact[DisconnectOnce]=$(as_bool in_order '^  if not server\.clients\[client\.id\] then$' '^    return$' \
  '^  server\.on_disconnect\(client, code, reason\)$' '^  M\._remove_client\(server, client\)$' <<<"$disconnect")
# _remove_client clears the client and releases its socket, and release_socket closes the handle.
disconnect_closes_socket() {
  in_order '^  if server\.clients\[client\.id\] then$' '^    server\.clients\[client\.id\] = nil$' \
    '^    release_socket\(client\)$' <<<"$remove_client" &&
    in_order '^  client\.tcp_handle:close\(\)$' <<<"$release_socket"
}
fact[DisconnectClosesSocket]=$(as_bool disconnect_closes_socket)
# _disconnect_client releases the socket of a client that is no longer listed before it returns.
fact[UnlistedDisconnectReleases]=$(as_bool in_order '^  if not server\.clients\[client\.id\] then$' \
  '^    release_socket\(client\)$' '^    return$' <<<"$disconnect")
# release_socket leaves a handle alone while the Close write callback will close it. close_client sets close_pending
# before it writes the frame, and its write callback clears it and closes the handle. drop_client (the keepalive
# check) calls abandon_close_frame, which clears it too, so that a timed-out client does not wait for the write.
close_write_owns_socket() {
  in_order '^local function release_socket\(client\)$' \
    '^  if client\.close_pending or client\.tcp_handle:is_closing\(\) then$' '^    return$' \
    '^  client\.tcp_handle:close\(\)$' <<<"$release_socket" &&
    in_order '^    client\.close_pending = true$' '^    write\(client, close_frame, function\(\)$' \
      '^      client\.close_pending = nil$' '^      client\.state = "closed"$' '^        client\.tcp_handle:close\(\)$' \
      <<<"$close_client" &&
    in_order '^  client_manager\.close_client\(client, 1011, close_reason\)$' \
      '^  client_manager\.abandon_close_frame\(client\)$' '^  M\._disconnect_client\(server, client, 1006, disconnect_reason\)$' \
      <<<"$drop_client" &&
    in_order '^function M\.abandon_close_frame\(client\)$' '^  client\.close_pending = nil$' <<<"$abandon_close_frame"
}
fact[CloseWriteOwnsSocket]=$(as_bool close_write_owns_socket)
fact[RejectClosesSocket]=$(as_bool in_order '^ *if err or not success then$' '^ *on_error\(client, ' \
  '^ *if not client\.tcp_handle:is_closing\(\) then$' '^ *client\.tcp_handle:close\(\)$' '^ *return$' \
  <<<"$process_data")
# Each of the two protocol-error closes in process_data (a frame that parse_frame rejects, a data message that breaks the
# protocol) goes through fail_connection, which closes with the status and then calls on_error at once. close_client
# has no on_done.
protocol_reports_at_once() {
  [[ $(grep -cE '^ *fail_connection\(client, [^)]*, on_error\)$' <<<"$process_data") == 2 ]] &&
    in_order '^local function fail_connection\(client, status, problem, on_error\)$' \
      '^  M\.close_client\(client, status, CLOSE_REASONS\[status\]\)$' '^  on_error\(client, problem\)$' \
      <<<"$fail_connection" &&
    ! grep -q 'on_done' <<<"$close_client"
}
fact[ProtocolReportsAtOnce]=$(as_bool protocol_reports_at_once)
# stop_server only calls close_client for each client: the Close write callback closes the socket.
stop_waits_for_close_write() {
  grep -qE '^    client_manager\.close_client\(client, 1001, "Server shutting down"\)$' <<<"$stop_server" &&
    ! grep -qE 'tcp_handle|_remove_client|_disconnect_client' <<<"$stop_server" &&
    in_order '^    write\(client, close_frame, function\(\)$' '^        client\.tcp_handle:close\(\)$' \
      <<<"$close_client"
}
fact[StopWaitsForCloseWrite]=$(as_bool stop_waits_for_close_write)
# The ping timer arms after_next_poll once for the clients it pinged. The callback runs judge_silence with a limit of
# interval * 2.5 (the third tick after the stamp, the model's Limit). judge_silence drops a client that is still listed and
# connected and whose stamp is that old, with drop_client: close_client(1011), abandon_close_frame, _disconnect_client(1006).
keepalive_reaps() {
  in_order '^    if #pinged > 0 then$' '^      after_next_poll\(server, function\(\)$' \
    '^          judge_silence\(server, pinged, interval \* 2\.5\)$' <<<"$ping_timer" &&
    in_order '^local function judge_silence\(server, clients, limit\)$' '^  local now = vim\.loop\.now\(\)$' \
      '^  for _, client in ipairs\(clients\) do$' '^    local since = client\.ping_unanswered_since$' \
      '^    if server\.clients\[client\.id\] == client and client\.state == "connected" and since and now - since >= limit then$' \
      '^      drop_client\(server, client, "Keepalive timeout", "Connection timeout"\)$' <<<"$judge_silence" &&
    in_order '^  client_manager\.close_client\(client, 1011, close_reason\)$' \
      '^  client_manager\.abandon_close_frame\(client\)$' '^  M\._disconnect_client\(server, client, 1006, disconnect_reason\)$' <<<"$drop_client"
}
fact[KeepaliveReaps]=$(as_bool keepalive_reaps)
# Only the callback that after_next_poll runs after a libuv check handle drops a client: libuv runs the check handle after
# the poll phase that reads the sockets. The timer callback closes and disconnects nothing, and arms the callback for the
# clients it pinged.
judges_after_read() {
  ! { grep -vE '^ *--' <<<"$ping_timer" | grep -qE 'close_client|_disconnect_client|drop_client'; } &&
    in_order '^  local check = vim\.loop\.new_check\(\)$' '^  check:start\(function\(\)$' '^    fn\(\)$' <<<"$after_next_poll"
}
fact[JudgesAfterRead]=$(as_bool judges_after_read)
# The tick calls update_time before it reads the clock for the wake test, the stamp and the gap: libuv runs the timers of a
# pass with the loop time of the start of the pass, and a callback that ran earlier in the pass can have blocked since,
# or the machine can have slept in it.
fact[ClockFreshAtTick]=$(as_bool in_order '^    vim\.loop\.update_time\(\)$' '^    local now = vim\.loop\.now\(\)$' \
  '^    local elapsed = now - last_run$' '^        client\.ping_unanswered_since = since or now$' '^      local tick_time = now$' <<<"$ping_timer")
# A ping that finds a stamp leaves it, so the stamp is the oldest ping that no pong has answered.
stamp_keeps_oldest_ping() {
  in_order '^        local since = client\.ping_unanswered_since$' '^        client\.ping_unanswered_since = since or now$' <<<"$ping_timer"
}
fact[StampKeepsOldestPing]=$(as_bool stamp_keeps_oldest_ping)
# Any bytes that the read callback gets clear the stamp, before process_data runs: a pong can wait behind more unread data
# than the socket holds, and one poll does not reach it.
fact[BytesClearStamp]=$(as_bool in_order '^  client_tcp:read_start\(function\(err, data\)$' '^    if not data then$' \
  '^    client\.ping_unanswered_since = nil$' '^    client_manager\.process_data\(client, data, ' <<<"$new_connection")
# The callback judges the silence only when its loop time is at most interval * 1.5 after its tick: the machine can have
# slept between the tick and the poll, and Claude with it.
fact[GapSkip]=$(as_bool in_order '^      local tick_time = now$' '^      after_next_poll\(server, function\(\)$' \
  '^        if vim\.loop\.now\(\) - tick_time <= interval \* 1\.5 then$' '^          judge_silence\(server, pinged, interval \* 2\.5\)$' <<<"$ping_timer")
fact[WakeClearsStamp]=$(as_bool in_order '^    local is_wake_from_sleep = elapsed > \(interval \* 1\.5\)$' \
  '^    if is_wake_from_sleep then$' '^      for _, client in pairs\(server\.clients\) do$' '^        if client\.state == "connected" then$' \
  '^          client\.ping_unanswered_since = nil$' '^    last_run = now$' <<<"$ping_timer")

# NoFalseTimeout is a safety rule, but it runs alone (as [](~falseTimeout)): TLC stops at the first broken invariant
# of a run, and its known finding is shorter than any break of the other three.
RULES=(NoRequestAfterEnd DisconnectReportedOnce StatusCloseDelivered)
LIVE=(NoFalseTimeout DeadClientDropped DroppedSocketCloses)
EXPECT=(
  [UpgradeInWriteCallback]=NoRequestAfterEnd [UpgradeRechecksState]=NoRequestAfterEnd
  [DispatchGuard]=NoRequestAfterEnd [PeerCloseMarksClosing]=NoRequestAfterEnd
  [DisconnectOnce]=DisconnectReportedOnce
  [CloseWriteOwnsSocket]=StatusCloseDelivered [StopWaitsForCloseWrite]=StatusCloseDelivered
  [BytesClearStamp]=NoFalseTimeout [GapSkip]=NoFalseTimeout [WakeClearsStamp]=NoFalseTimeout [ClockFreshAtTick]=NoFalseTimeout
  [JudgesAfterRead]=NoFalseTimeout [StampKeepsOldestPing]=DeadClientDropped
  [KeepaliveReaps]=DeadClientDropped [ProtocolReportsAtOnce]=DeadClientDropped
  [DisconnectClosesSocket]=DroppedSocketCloses [UnlistedDisconnectReleases]=DroppedSocketCloses
  ["RejectClosesSocket+UnlistedDisconnectReleases"]=DroppedSocketCloses
)
MUTANT_NOTES=("  RejectClosesSocket alone is caught by no rule: _disconnect_client also closes the socket of a client that left the server.")

# Safety rules: one connection, Claude sends 3 frames (its upgrade request included), two delayed ticks (a gap above
# 1.5 intervals, a tick in a pass that an earlier callback blocked, or a sleep between a tick and its poll). Liveness rules: 2 frames and no delayed tick,
# which keeps each run under 10 s. DroppedSocketCloses alone assumes that Claude reads again. NoFalseTimeout alone
# assumes that a Claude that reads answers a ping before the next tick.
tla_constants() {
  local reads=FALSE answers=FALSE
  [[ $1 != *DroppedSocketCloses ]] || reads=TRUE
  [[ $1 != *NoFalseTimeout ]] || answers=TRUE
  echo "  Conns = {c1}"
  case $1 in
  *DeadClientDropped | *DroppedSocketCloses)
    echo "  PeerBudget = 2"
    echo "  MaxSleeps = 0"
    ;;
  *)
    echo "  PeerBudget = 3"
    echo "  MaxSleeps = 2"
    ;;
  esac
  echo "  PeerEventuallyReads = $reads"
  echo "  PeerAnswersBeforeTick = $answers"
  # The environment steps of the bugs this model found. Every run allows them, so that a removed guard breaks a rule.
  echo "  WindowFullOnProtocolClose = TRUE"
  echo "  StopBeforeOnClose = TRUE"
  echo "  StaleLoopTime = TRUE"
  echo "  PollMissesPong = TRUE"
  echo "  SleepInWindow = TRUE"
}

tla_main "$@"

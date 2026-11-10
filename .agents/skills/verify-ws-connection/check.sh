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
SITE_RE='(close_client|_disconnect_client|_remove_client|stop_server|start_ping_timer|send_ping|is_client_alive|tcp_handle:(write|close|read_start)|client\.state = |handshake_complete = |last_pong = |server\.clients\[|server\.stop\(\)|ping_timer:)'

covered_block create_client "$CLIENT" '^function M\.create_client\('
covered_block add_data_frame "$CLIENT" '^local function add_data_frame\('
covered_block process_data "$CLIENT" '^function M\.process_data\('
covered_block send_message "$CLIENT" '^function M\.send_message\('
covered_block send_ping "$CLIENT" '^function M\.send_ping\('
covered_block fail_connection "$CLIENT" '^local function fail_connection\('
covered_block close_client "$CLIENT" '^function M\.close_client\('
covered_block is_alive "$CLIENT" '^function M\.is_client_alive\('
covered_block new_connection "$TCP" '^function M\._handle_new_connection\('
covered_block release_socket "$TCP" '^local function release_socket\('
covered_block disconnect "$TCP" '^function M\._disconnect_client\('
covered_block remove_client "$TCP" '^function M\._remove_client\('
covered_block stop_server "$TCP" '^function M\.stop_server\('
covered_block ping_timer "$TCP" '^function M\.start_ping_timer\('
covered_block process_handshake "$HANDSHAKE" '^function M\.process_handshake\('
covered_block extract_request "$HANDSHAKE" '^function M\.extract_http_request\('
covered_block server_start "$SERVER" '^function M\.start\('
covered_block server_stop "$SERVER" '^function M\.stop\(\)'
covered_block main_start "$MAIN" '^function M\.start\('
covered_block main_stop "$MAIN" '^function M\.stop\(\)'

FACTS=(UpgradeInWriteCallback UpgradeRechecksState UpgradeStartsKeepalive DispatchGuard PeerCloseMarksClosing
  DisconnectOnce DisconnectClosesSocket UnlistedDisconnectReleases CloseWriteOwnsSocket RejectClosesSocket
  ProtocolReportsAtOnce StopWaitsForCloseWrite KeepaliveReaps DropsOnSecondOverdueTick AliveTickClearsOverdue
  PongResetsAge WakeResetsPong)

# The handshake completes in the 101 write callback, after its error check, and nowhere before.
upgrade_in_write_callback() {
  [[ $(grep -c 'client\.handshake_complete = true' <<<"$process_data") == 1 ]] &&
    in_order '^ *if success then$' '^ *client\.state = "upgrading"$' \
      '^ *client\.tcp_handle:write\(response_from_handshake, function\(err\)$' '^ *if err or not success then$' \
      '^ *client\.handshake_complete = true$' '^ *client\.state = "connected"$' <<<"$process_data"
}
fact[UpgradeInWriteCallback]=$(as_bool upgrade_in_write_callback)
fact[UpgradeRechecksState]=$(as_bool in_order 'client\.tcp_handle:write\(response_from_handshake, function\(err\)$' \
  '^ *if client\.state ~= "upgrading" or client\.tcp_handle:is_closing\(\) then$' '^ *return$' \
  '^ *client\.handshake_complete = true$' <<<"$process_data")
# The 101 write callback starts the keepalive window: the ping timer ignores a client that is not connected, so
# last_pong from the accept can be older than the timeout when the client becomes connected.
fact[UpgradeStartsKeepalive]=$(as_bool in_order '^ *client\.handshake_complete = true$' '^ *client\.state = "connected"$' \
  '^ *client\.last_pong = vim\.loop\.now\(\)$' '^ *logger\.debug\("client", "WebSocket connection established' <<<"$process_data")
fact[DispatchGuard]=$(as_bool in_order '^ *vim\.schedule\(function\(\)$' \
  '^ *if client\.state == "connected" and not client\.tcp_handle:is_closing\(\) then$' \
  '^ *on_message\(client, message\)$' <<<"$process_data")
fact[PeerCloseMarksClosing]=$(as_bool in_order 'elseif opcode == frame\.OPCODE\.CLOSE then$' \
  '^ *if client\.state == "connected" then$' '^ *client\.tcp_handle:write\(close_frame\)$' \
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
# before it writes the frame, and its write callback clears it and closes the handle. The ping timer clears it too,
# so that a timed-out client does not wait for the write.
close_write_owns_socket() {
  in_order '^local function release_socket\(client\)$' \
    '^  if client\.close_pending or client\.tcp_handle:is_closing\(\) then$' '^    return$' \
    '^  client\.tcp_handle:close\(\)$' <<<"$release_socket" &&
    in_order '^    client\.close_pending = true$' '^    client\.tcp_handle:write\(close_frame, function\(\)$' \
      '^      client\.close_pending = nil$' '^      client\.state = "closed"$' '^        client\.tcp_handle:close\(\)$' \
      <<<"$close_client" &&
    in_order '^          client_manager\.close_client\(client, 1011, "Keepalive timeout"\)$' \
      '^          client\.close_pending = nil$' '^          M\._disconnect_client\(server, client, 1006, "Connection timeout"\)$' \
      <<<"$ping_timer"
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
    in_order '^    client\.tcp_handle:write\(close_frame, function\(\)$' '^        client\.tcp_handle:close\(\)$' \
      <<<"$close_client"
}
fact[StopWaitsForCloseWrite]=$(as_bool stop_waits_for_close_write)
fact[KeepaliveReaps]=$(as_bool in_order '^    for _, client in pairs\(server\.clients\) do$' \
  '^      if client\.state == "connected" then$' '^        if client_manager\.is_client_alive\(client, interval \* 2\) then$' \
  '^          client_manager\.send_ping\(client, "ping"\)$' '^        else$' \
  '^          client_manager\.close_client\(client, 1011, "Keepalive timeout"\)$' \
  '^          M\._disconnect_client\(server, client, 1006, "Connection timeout"\)$' <<<"$ping_timer")
# The first tick that finds no pong for two intervals pings again and sets pong_overdue. Only the second one drops the
# client, after a pong that was unread at a late tick had its chance to be read.
fact[DropsOnSecondOverdueTick]=$(as_bool in_order '^        if client_manager\.is_client_alive\(client, interval \* 2\) then$' \
  '^        elseif not client\.pong_overdue then$' '^          client\.pong_overdue = true$' \
  '^          client_manager\.send_ping\(client, "ping"\)$' '^        else$' \
  '^          client_manager\.close_client\(client, 1011, "Keepalive timeout"\)$' <<<"$ping_timer")
fact[AliveTickClearsOverdue]=$(as_bool in_order '^        if client_manager\.is_client_alive\(client, interval \* 2\) then$' \
  '^          client\.pong_overdue = nil$' '^          client_manager\.send_ping\(client, "ping"\)$' '^        elseif not client\.pong_overdue then$' \
  <<<"$ping_timer")
fact[PongResetsAge]=$(as_bool in_order 'elseif opcode == frame\.OPCODE\.PONG then$' \
  '^ *client\.last_pong = vim\.loop\.now\(\)$' <<<"$process_data")
fact[WakeResetsPong]=$(as_bool in_order '^    local is_wake_from_sleep = elapsed > \(interval \* 1\.5\)$' \
  '^    if is_wake_from_sleep then$' '^      for _, client in pairs\(server\.clients\) do$' \
  '^        if client\.state == "connected" then$' '^          client\.last_pong = now$' \
  '^    last_run = now$' <<<"$ping_timer")

# NoFalseTimeout is a safety rule, but it runs alone (as [](~falseTimeout)): TLC stops at the first broken invariant
# of a run, and its known finding is shorter than any break of the other three.
RULES=(NoRequestAfterEnd DisconnectReportedOnce StatusCloseDelivered)
LIVE=(NoFalseTimeout DeadClientDropped DroppedSocketCloses)
EXPECT=(
  [UpgradeInWriteCallback]=NoRequestAfterEnd [UpgradeRechecksState]=NoRequestAfterEnd
  [DispatchGuard]=NoRequestAfterEnd [PeerCloseMarksClosing]=NoRequestAfterEnd
  [DisconnectOnce]=DisconnectReportedOnce
  [CloseWriteOwnsSocket]=StatusCloseDelivered [StopWaitsForCloseWrite]=StatusCloseDelivered
  [UpgradeStartsKeepalive]=NoFalseTimeout [PongResetsAge]=NoFalseTimeout [WakeResetsPong]=NoFalseTimeout
  [KeepaliveReaps]=DeadClientDropped [ProtocolReportsAtOnce]=DeadClientDropped
  [DropsOnSecondOverdueTick]=NoFalseTimeout [AliveTickClearsOverdue]=NoFalseTimeout
  [DisconnectClosesSocket]=DroppedSocketCloses [UnlistedDisconnectReleases]=DroppedSocketCloses
  ["RejectClosesSocket+UnlistedDisconnectReleases"]=DroppedSocketCloses
)
MUTANT_NOTES=("  RejectClosesSocket alone is caught by no rule: _disconnect_client also closes the socket of a client that left the server.")

# Safety rules: one connection, Claude sends 3 frames (its upgrade request included), two delayed ticks (a gap above
# 1.5 intervals, or a late tick). Liveness rules: 2 frames and no delayed tick, which keeps each run under 10 s. DroppedSocketCloses alone assumes that Claude reads again.
tla_constants() {
  local reads=FALSE
  [[ $1 != *DroppedSocketCloses ]] || reads=TRUE
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
  # The environment steps of the three bugs this model found. Every run allows them, so that a removed guard breaks a rule.
  echo "  GapDuringHandshake = TRUE"
  echo "  WindowFullOnProtocolClose = TRUE"
  echo "  StopBeforeOnClose = TRUE"
  echo "  LateTickAfterPing = TRUE"
}

tla_main "$@"

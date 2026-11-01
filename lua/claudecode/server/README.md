# claudecode.server

## Overview

`claudecode.server` is the plugin's built-in Model Context Protocol (MCP) server. It is a pure-Lua WebSocket (RFC 6455) server on top of `vim.loop` TCP handles. It speaks JSON-RPC 2.0 to the Claude Code CLI. It listens only on `127.0.0.1`, checks an auth token during the HTTP upgrade, and sends MCP tool calls to [`../tools/README.md`](../tools/README.md).

Layers, top to bottom:

1. `init.lua`: server lifecycle, MCP method table, JSON-RPC dispatch, and deferred responses.
2. `tcp.lua`: port selection, listen socket, client registry, and the keep-alive ping timer.
3. `client.lua`: per-connection state machine (handshake, then frames).
4. `handshake.lua` and `frame.lua`: HTTP upgrade validation and frame encode/decode.
5. `utils.lua`: base64, SHA-1, masking, UTF-8, and constant-time compare helpers.

`mock.lua` is an in-memory stand-in with no sockets. Nothing in `lua/` or `tests/` requires it.

## Interface

### Lifecycle and messaging (`init.lua`)

- `M.state`: `{ server, port, auth_token, handlers, ping_timer }` [server/init.lua:M.state]
- `M.start(config, auth_token) -> ok, port|err`: calls `tools.setup(M)`, registers handlers, creates the TCP server, and starts the ping timer [server/init.lua:M.start]
- `M.stop() -> ok, err?`: stops the ping timer, closes pending diffs, stops the TCP server, and clears deferred responses [server/init.lua:M.stop]
- `M.register_handlers()`: handles `initialize`, `notifications/initialized`, `prompts/list`, `tools/list`, and `tools/call` [server/init.lua:M.register_handlers]
- `initialize` returns `protocolVersion = "2024-11-05"` (`MCP_PROTOCOL_VERSION`), `capabilities` (logging, `prompts.listChanged`, `tools.listChanged`), and `serverInfo.name = "claudecode-neovim"` [server/init.lua:MCP_PROTOCOL_VERSION]
- `tools/call` delegates to `tools.handle_invoke` and returns a `_deferred` table for blocking tools [server/init.lua:M.register_handlers]
- `M.send(client, method, params) -> boolean`: sends a JSON-RPC notification to one client [server/init.lua:M.send]
- `M.send_response(client, id, result, error_data) -> boolean`: a `nil` id is sent as JSON `null` (`vim.NIL`) [server/init.lua:M.send_response]
- `M.broadcast(method, params) -> boolean`: sends a notification to all clients [server/init.lua:M.broadcast]
- `M.get_status() -> { running, port, client_count, clients }`. `clients` is present only while the server runs [server/init.lua:M.get_status]
- Internal dispatch: `M._handle_message`, `M._handle_request`, `M._handle_notification`, and `M._setup_deferred_response` [server/init.lua:M._handle_message]

### TCP server (`tcp.lua`)

- `M.create_server(config, callbacks, auth_token) -> server|nil, err`: tries ports in the configured range until one binds and listens [server/tcp.lua:M.create_server]
- `M.find_available_port(min_port, max_port)`: probe-only port check [server/tcp.lua:M.find_available_port]
- `M.send_to_client`, `M.broadcast`, `M.close_client`, `M.get_client_count`, and `M.get_clients_info` [server/tcp.lua:M.send_to_client]
- `M.stop_server(server)`: sends a Close frame with code 1001 "Server shutting down" to clients that finished the handshake, closes the TCP handle of the others, then closes the listener [server/tcp.lua:M.stop_server] [server/client.lua:M.close_client]
- `M.start_ping_timer(server, interval)`: default interval is 30000 ms [server/tcp.lua:M.start_ping_timer]
- Internal: `M._bind_and_listen`, `M._handle_new_connection`, `M._disconnect_client`, and `M._remove_client` [server/tcp.lua:M._bind_and_listen]

### Connection, handshake, and frames

- `client.create_client(tcp_handle)`, `process_data(...)`, `send_message`, `send_ping`, `close_client`, `is_client_alive(client, timeout=30000)`, and `get_client_info` [server/client.lua:M.process_data]
- `handshake.process_handshake(request, expected_auth_token) -> ok, response, headers?` [server/handshake.lua:M.process_handshake]
- `handshake.validate_upgrade_request`, `create_handshake_response`, `parse_request_line`, `is_websocket_endpoint`, `create_error_response`, and `extract_http_request` [server/handshake.lua:M.validate_upgrade_request]
- `frame.OPCODE`: `CONTINUATION 0x0`, `TEXT 0x1`, `BINARY 0x2`, `CLOSE 0x8`, `PING 0x9`, `PONG 0xA` [server/frame.lua:M.OPCODE]
- `frame.MAX_PAYLOAD_LENGTH`: 100 MiB, the largest frame payload and the largest message [server/frame.lua:M.MAX_PAYLOAD_LENGTH]
- `frame.parse_frame(data, start?) -> frame|nil, consumed, close_code?, detail?`: parses the frame that starts at byte `start` (default 1). `nil, 0` means incomplete, and `nil, 0, nil, length` gives the whole frame's length once its header arrived. `nil, 0, code, problem` means fatal, with the broken rule in `problem` [server/frame.lua:M.parse_frame]
- `frame.create_frame`, `create_text_frame`, `create_binary_frame`, `create_close_frame`, `create_ping_frame`, `create_pong_frame`, and `is_control_frame` [server/frame.lua:M.create_frame]

### Helpers (`utils.lua`)

- `generate_accept_key`, `sha1`, `base64_encode`, `base64_decode`, `generate_websocket_key`, `parse_http_headers`, `is_valid_utf8`, `apply_mask`, `constant_time_compare`, `uint16_to_bytes`, `uint64_to_bytes`, `bytes_to_uint16`, and `bytes_to_uint64` [server/utils.lua:M.generate_accept_key]

### Mock (`mock.lua`)

- `M.state`, `start`, `stop`, `register_handlers` (`mcp.connect`, `mcp.tool.invoke`), `add_client`, `remove_client`, `send`, `send_response`, `broadcast`, `simulate_message`, and `clear_messages` [server/mock.lua:M.register_handlers]
- `M.find_available_port(min, max)`: always returns `min` [server/mock.lua:M.find_available_port]

## Invariants

- The server listens only on `127.0.0.1` with backlog 128. It closes the handle if bind or listen fails [server/tcp.lua:M._bind_and_listen]
- The port iterator yields each port in the range exactly once, starting at a random offset. `create_server` returns "No available ports in range min-max" for an empty range, and "No free port in min-max (<libuv error>)" when every port fails [server/tcp.lua:M.create_server]
- `M.start` refuses with "Server already running" when `M.state.server` is set. `M.stop` returns "Server not running" when it is not set. `send`, `send_response`, and `broadcast` return `false` without a server [server/init.lua:M.start]
- When an auth token is set, the upgrade request must carry `x-claude-code-ide-authorization`. The header length must be 10..500. The token is compared with `utils.constant_time_compare` [server/handshake.lua:M.validate_upgrade_request]
- The upgrade request must have `Upgrade: websocket`, `Connection` containing `upgrade`, `Sec-WebSocket-Version: 13`, and a 24-character `Sec-WebSocket-Key` [server/handshake.lua:M.validate_upgrade_request]
- A non-GET or non-HTTP/1.1 request gets 404. A failed validation gets 400 "Bad WebSocket upgrade request: <reason>" [server/handshake.lua:M.process_handshake]
- Frames are dispatched only after `handshake_complete` is true. The state becomes `connected` only after a successful handshake [server/client.lua:M.process_data]
- A text message can arrive in fragments (a TEXT frame with FIN clear, then CONTINUATION frames up to one with FIN set), with control frames between them. `process_data` joins the fragments and calls `on_message` once with the whole text. Only the whole message must be well-formed UTF-8, and one that is not closes with 1007. A binary message closes with 1003, and nothing runs it. A CONTINUATION frame with no message to continue, or a TEXT or BINARY frame inside a fragmented message, closes with 1002. A message whose fragments add up to more than `frame.MAX_PAYLOAD_LENGTH` (100 MiB) closes with 1009. An unknown opcode closes with 1002. Each Close frame carries the RFC 6455 name of its status as the reason: `Protocol error` (1002), `Unsupported data` (1003), `Invalid frame payload data` (1007) or `Message too big` (1009) [server/client.lua:add_data_frame] [server/client.lua:M.process_data]
- `process_data` parses every frame of one read from an offset into its buffer and keeps the unparsed rest once at the end, so many small frames in one read cost linear time. The reads of a frame longer than one read wait in `client.pending` until the whole frame arrived, and are joined once, so a large frame costs linear time too [server/client.lua:M.process_data]
- `parse_frame` rejects set RSV bits, invalid opcodes, fragmented control frames, and control payloads over 125 bytes with 1002. It rejects a payload over `MAX_PAYLOAD_LENGTH` (100 MiB) with 1009, and a close reason that is not well-formed UTF-8 with 1007. It names the broken rule (for example `Reserved opcode 0x3`), and that name is the client's disconnect reason. It does not check the UTF-8 of a text frame, because a fragment can end inside a code point. `is_valid_utf8` uses `utils.utf8_sequence_length`, the decoder behind the outbound `utils.valid_utf8`, so it also rejects overlong forms, UTF-16 surrogates, code points above U+10FFFF, and the bytes C0, C1 and F5 to FF [server/frame.lua:M.parse_frame] [server/utils.lua:M.is_valid_utf8]
- `parse_frame` does not reject unmasked client frames. Server frames are unmasked by default (`masked=false`) [server/frame.lua:M.create_frame]
- Every text frame the server sends is valid UTF-8. `send_message` replaces each ill-formed sequence with U+FFFD, so a buffer name or path with invalid bytes reaches the client as U+FFFD and does not drop the connection [server/client.lua:M.send_message]
- JSON-RPC errors: -32700 for a parse error and -32600 unless `jsonrpc == "2.0"` [server/init.lua:M._handle_message]. -32601 for an unknown method and -32603 for a handler that raises [server/init.lua:M._handle_request]
- When the JSON decodes to a non-table value (for example a number or a boolean), `_handle_message` replies -32600 with `"id": null`. It does not raise [server/init.lua:M._handle_message]
- A message with a truthy `id` is a request. Any other message is a notification. A valid notification never gets a response. The -32700 and -32600 checks run before the `id` check, so a malformed notification gets an error reply [server/init.lua:M._handle_message]
- A deferred response is keyed by `tostring(coroutine)` in `_G.claude_deferred_responses`. A result with neither `content` nor `error` becomes -32603 [server/init.lua:M._setup_deferred_response]
- The ping timer closes a connected client when no pong arrived within `interval * 2`: its Close frame carries 1011 "Keepalive timeout" (RFC 6455 reserves 1006, so no Close frame carries it), `on_disconnect` gets 1006 "Connection timeout", and the timer logs `Closed client_<n>: no reply for <s>s` at info level. A tick gap above `interval * 1.5` counts as a wake from sleep and resets `last_pong` [server/tcp.lua:M.start_ping_timer]
- `_disconnect_client` is idempotent: `on_disconnect` fires once per client id [server/tcp.lua:M._disconnect_client]
- A client's read error or protocol error reaches the server only as its `on_disconnect` reason (`Client read error: …` or `Client error: …`), which `init.lua` logs at debug level. `on_error` carries only the server's own failures (listen, accept, and creating a client handle or the ping timer), which `init.lua` logs at error level [server/tcp.lua:M._handle_new_connection] [server/init.lua:M.start]
- A rejected handshake logs `Rejected client_<n>: <reason>` at warn level, with the reason from the body of the error response. Once the error response is written, `on_error` removes the client from the server and closes its socket [server/client.lua:M.process_data]
- Once a client is closing, `process_data` drops the bytes it sends, and `close_client` frees the unparsed bytes and the reads of an unfinished frame [server/client.lua:M.process_data] [server/client.lua:M.close_client]
- The server logs each error, warning, and info line from a libuv callback through `logger.one_line`, so the line never stops Neovim at "Press ENTER" [server/init.lua:M.start] [server/client.lua:M.process_data] [server/tcp.lua:M.start_ping_timer]
- Each connection gets the id `client_<n>`, where `n` counts the connections of this Neovim process in `_G.claudecode_clients_created`. An id never repeats, even after a reload of `claudecode.server.*`. A Claude CLI that reconnects gets a new id, so it does not own the diffs it opened before [server/client.lua:M.create_client]
- When the state is already `closing` or `closed`, `close_client` sends nothing. It still schedules `on_done` if one is given [server/client.lua:M.close_client]
- `sha1` rejects non-string input and input over 10 MiB [server/utils.lua:M.sha1]

## Side Effects

- `M.start` changes the global tool registry (`tools.setup`), opens a listening TCP handle, and starts a `vim.loop` ping timer [server/init.lua:M.start]
- On connect, the server schedules `claudecode.process_mention_queue(true)` [server/init.lua:M.start]
- On disconnect, the server schedules `diff.close_diffs_for_client(client.id, "client disconnected")`, only when `package.loaded["claudecode.diff"]` is set [server/init.lua:M.start]
- `M.stop` calls `diff.close_pending_diffs("server stopping")` when `package.loaded["claudecode.diff"]` is set, resets `_G.claude_deferred_responses`, and clears `M.state.auth_token` [server/init.lua:M.stop]
- `M.start` logs only the auth token length, not the token [server/init.lua:M.start]
- `tools/call` debug lines name the tool and list the argument and result keys with their sizes (string bytes, table entry counts), never their values, so file contents and selected text stay out of `:messages`. An error result logs its code and message [server/init.lua:M.register_handlers]
- `client.create_client` increments `_G.claudecode_clients_created` [server/client.lua:M.create_client]
- `tcp.lua` seeds `math.randomseed` once per process. `init.lua` calls `math.random` at load. Both change the global PRNG [server/tcp.lua:ensure_rng_seeded]
- `client.process_data` writes handshake, PONG, and Close frames to the socket. It runs `on_message` and `on_close` through `vim.schedule`. It calls `on_error` directly after a failed handshake write, and after it writes the Close frame for a protocol error [server/client.lua:M.process_data] [server/client.lua:M.close_client]
- The ping timer writes ping frames and closes timed-out clients [server/tcp.lua:M.start_ping_timer]
- `handshake.lua`, `frame.lua`, and `utils.lua` do no I/O [server/handshake.lua:M]
- `mock.lua` opens no sockets and keeps its clients and messages in its own `M.state` tables. Its `mcp.tool.invoke` handler calls the real `tools.handle_invoke`, so a simulated tool call has that tool's real side effects (for example `saveDocument` writes the file) [server/mock.lua:M.register_handlers] [server/mock.lua:M.state]

## Verification

- Run: `mise run test`
- Targeted: `busted -v tests/unit/server/frame_spec.lua`, `busted -v tests/unit/server/handshake_spec.lua`, `busted -v tests/unit/server/tcp_spec.lua`, `busted -v tests/unit/server_spec.lua`

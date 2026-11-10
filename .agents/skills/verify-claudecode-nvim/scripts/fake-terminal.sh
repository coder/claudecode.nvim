#!/bin/sh
# Stands in for the `claude` CLI inside a plugin-managed terminal (terminal_cmd). It prints a banner, then idles, so a
# run needs no credentials and the real CLI never starts. The scripted client plays Claude over the WebSocket.
echo "FAKE CLAUDE TERMINAL (verify-claudecode-nvim)"
exec sleep 900

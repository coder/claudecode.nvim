# lua

## Overview

`lua/` is the Neovim runtime path for the plugin's Lua modules. It holds no source files of its own. Its one child,
`claudecode/`, is the module that `require("claudecode")` loads. That package owns setup, the `:ClaudeCode*` commands,
the lock file, the terminal, diffs, selection tracking, and the MCP WebSocket server.

## Subdirectories & Boundaries

- claudecode: [./claudecode/README.md](./claudecode/README.md) - Core package: `setup`/`start`/`stop` and the
  `:ClaudeCode*` commands (`init.lua`), config validation, lock-file discovery with an auth token, the terminal
  dispatcher, blocking diffs, selection tracking, and `:checkhealth`. Its child contracts are
  [server](./claudecode/server/README.md) (RFC 6455 WebSocket and JSON-RPC 2.0 MCP server bound to `127.0.0.1`),
  [terminal](./claudecode/terminal/README.md) (native, snacks, external, and none providers, plus `paste_fix`), and
  [tools](./claudecode/tools/README.md) (MCP tool registry with 10 listed tools and the hidden `close_tab`).

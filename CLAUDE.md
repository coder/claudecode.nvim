# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Neovim plugin that integrates with Claude Code CLI to provide seamless AI coding experience. The plugin creates a WebSocket server using pure Neovim built-ins to communicate with Claude Code CLI via JSON-RPC 2.0, implementing the Model Context Protocol (MCP).

## Common Development Commands

### Testing

- `make test` - Run all tests using busted
- `./run_tests.sh` - Direct test runner script
- `busted tests/unit/specific_spec.lua` - Run specific test file
- `busted --coverage -v` - Run tests with coverage

### Code Quality

- `make check` - Check Lua syntax and run luacheck
- `make format` - Format code with stylua (or nix fmt if available)
- `luacheck lua/ tests/ --no-unused-args --no-max-line-length` - Direct linting

### Build Commands

- `make all` - Run check and format (default target)
- `make clean` - Remove generated test files
- `make help` - Show available commands

### Development with Nix

- `nix develop` - Enter development shell with all dependencies
- `nix fmt` - Format all files using nix formatter

## Architecture Overview

### Core Components

1. **WebSocket Server** (`lua/claudecode/server/`) - Pure Neovim implementation using vim.loop, RFC 6455 compliant
2. **MCP Tool System** (`lua/claudecode/tools/`) - Implements tools that Claude can execute (openFile, getCurrentSelection, etc.)
3. **Lock File System** (`lua/claudecode/lockfile.lua`) - Creates discovery files for Claude CLI at `~/.claude/ide/`
4. **Selection Tracking** (`lua/claudecode/selection.lua`) - Monitors text selections and sends updates to Claude
5. **Diff Integration** (`lua/claudecode/diff.lua`) - Native Neovim diff support for Claude's file comparisons
6. **Terminal Integration** (`lua/claudecode/terminal.lua`) - Manages Claude CLI terminal sessions

### WebSocket Server Implementation

- **TCP Server**: `server/tcp.lua` handles port binding and connections
- **Handshake**: `server/handshake.lua` processes HTTP upgrade requests
- **Frame Processing**: `server/frame.lua` implements RFC 6455 WebSocket frames
- **Client Management**: `server/client.lua` manages individual connections
- **Utils**: `server/utils.lua` provides base64, SHA-1, XOR operations in pure Lua

### MCP Tools Architecture

Tools are registered with JSON schemas and handlers. MCP-exposed tools include:

- `openFile` - Opens files with optional line/text selection
- `getCurrentSelection` - Gets current text selection
- `getOpenEditors` - Lists currently open files
- `openDiff` - Opens native Neovim diff views

### Key File Locations

- `lua/claudecode/init.lua` - Main entry point and setup
- `lua/claudecode/config.lua` - Configuration management
- `plugin/claudecode.lua` - Plugin loader with version checks
- `tests/` - Comprehensive test suite with unit, component, and integration tests

## Testing Architecture

Tests are organized in three layers:

- **Unit tests** (`tests/unit/`) - Test individual functions in isolation
- **Component tests** (`tests/component/`) - Test subsystems with controlled environment
- **Integration tests** (`tests/integration/`) - End-to-end functionality with mock Claude client

Test files follow the pattern `*_spec.lua` or `*_test.lua` and use the busted framework.

## Development Notes

- Plugin requires Neovim >= 0.8.0
- Uses only Neovim built-ins for WebSocket implementation (vim.loop, vim.json, vim.schedule)
- Lock files are created at `~/.claude/ide/[port].lock` for Claude CLI discovery
- WebSocket server only accepts local connections for security
- Selection tracking is debounced to reduce overhead
- Terminal integration supports both snacks.nvim and native Neovim terminal

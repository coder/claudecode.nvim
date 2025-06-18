# CLAUDE.md

This file provides context for Claude Code when working with this codebase.

## Project Overview

claudecode.nvim - A Neovim plugin that implements the same WebSocket-based MCP protocol as Anthropic's official IDE extensions. Built with pure Lua and zero dependencies.

## Common Development Commands

### Testing

- `make test` - Run all tests using busted with coverage
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

## Release Process

### Version Updates

When updating the version number for a new release, you must update **ALL** of these files:

1. **`lua/claudecode/init.lua`** - Main version table:

   ```lua
   M.version = {
     major = 0,
     minor = 2,  -- Update this
     patch = 0,  -- Update this
     prerelease = nil,  -- Remove for stable releases
   }
   ```

2. **`scripts/claude_interactive.sh`** - Multiple client version references:

   - Line ~52: `"version": "0.2.0"` (handshake)
   - Line ~223: `"version": "0.2.0"` (initialize)
   - Line ~309: `"version": "0.2.0"` (reconnect)

3. **`scripts/lib_claude.sh`** - ClaudeCodeNvim version:

   - Line ~120: `"version": "0.2.0"` (init message)

4. **`CHANGELOG.md`** - Add new release section with:
   - Release date
   - Features with PR references
   - Bug fixes with PR references
   - Development improvements

### Release Commands

```bash
# Get merged PRs since last version
gh pr list --state merged --base main --json number,title,mergedAt,url --jq 'sort_by(.mergedAt) | reverse'

# Get commit history
git log --oneline v0.1.0..HEAD

# Always run before committing
make

# Verify no old version references remain
rg "0\.1\.0" .  # Should only show CHANGELOG.md historical entries
```

## CRITICAL: Pre-commit Requirements

**ALWAYS run `make` before committing any changes.** This runs code quality checks and formatting that must pass for CI to succeed. Never skip this step - many PRs fail CI because contributors don't run the build commands before committing.

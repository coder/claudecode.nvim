# claudecode.nvim

[![Tests](https://github.com/coder/claudecode.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/coder/claudecode.nvim/actions/workflows/test.yml)
![Neovim version](https://img.shields.io/badge/Neovim-0.8%2B-green)
![Status](https://img.shields.io/badge/Status-beta-blue)

**The first Neovim IDE integration for Claude Code** — bringing Anthropic's AI coding assistant to your favorite editor with a pure Lua implementation.

> 🎯 **TL;DR:** When Anthropic released Claude Code with VS Code and JetBrains support, I reverse-engineered their extension and built this Neovim plugin. This plugin implements the same WebSocket-based MCP protocol, giving Neovim users the same AI-powered coding experience.

<https://github.com/user-attachments/assets/9c310fb5-5a23-482b-bedc-e21ae457a82d>

## What Makes This Special

When Anthropic released Claude Code, they only supported VS Code and JetBrains. As a Neovim user, I wanted the same experience — so I reverse-engineered their extension and built this.

- 🚀 **Pure Lua, Zero Dependencies** — Built entirely with `vim.loop` and Neovim built-ins
- 🔌 **100% Protocol Compatible** — Same WebSocket MCP implementation as official extensions
- 🎓 **Fully Documented Protocol** — Learn how to build your own integrations ([see PROTOCOL.md](./PROTOCOL.md))
- ⚡ **First to Market** — Beat Anthropic to releasing Neovim support
- 🛠️ **Built with AI** — Used Claude to reverse-engineer Claude's own protocol

## Quick Demo

```vim
" Launch Claude Code in a split
:ClaudeCode

" Claude now sees your current file and selections in real-time!

" Send visual selection as context
:'<,'>ClaudeCodeSend

" Claude can open files, show diffs, and more
```

## Requirements

- Neovim >= 0.8.0
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed
- Optional: [folke/snacks.nvim](https://github.com/folke/snacks.nvim) for enhanced terminal support

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "coder/claudecode.nvim",
  config = true,
  keys = {
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    -- Tree integration works automatically with the same keybinding
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", desc = "Add file to Claude context", ft = { "NvimTree", "neo-tree" } },
  },
}
```

That's it! For more configuration options, see [Advanced Setup](#advanced-setup).

## Usage

1. **Launch Claude**: Run `:ClaudeCode` to open Claude in a split terminal
2. **Send context**:
   - Select text in visual mode and use `<leader>as` to send it to Claude
   - In `nvim-tree` or `neo-tree`, press `<leader>as` on a file to add it to Claude's context
3. **Let Claude work**: Claude can now:
   - See your current file and selections in real-time
   - Open files in your editor
   - Show diffs with proposed changes
   - Access diagnostics and workspace info

## Commands

- `:ClaudeCode` - Toggle the Claude Code terminal window
- `:ClaudeCodeSend` - Send current visual selection to Claude, or add files from tree explorer
- `:ClaudeCodeTreeAdd` - Add selected file(s) from tree explorer to Claude context (also available via ClaudeCodeSend)

### Tree Integration

The `<leader>as` keybinding has context-aware behavior:

- **In normal buffers (visual mode)**: Sends selected text to Claude
- **In nvim-tree/neo-tree buffers**: Adds the file under cursor (or selected files) to Claude's context

This allows you to quickly add entire files to Claude's context for review, refactoring, or discussion.

#### Features:

- **Single file**: Place cursor on any file and press `<leader>as`
- **Multiple files**: Select multiple files (using tree plugin's selection features) and press `<leader>as`
- **Smart detection**: Automatically detects whether you're in nvim-tree or neo-tree
- **Error handling**: Clear feedback if no files are selected or if tree plugins aren't available

## How It Works

This plugin creates a WebSocket server that Claude Code CLI connects to, implementing the same protocol as the official VS Code extension. When you launch Claude, it automatically detects Neovim and gains full access to your editor.

### The Protocol

The extensions use a WebSocket-based variant of the Model Context Protocol (MCP) that only Claude Code supports. The plugin:

1. Creates a WebSocket server on a random port
2. Writes a lock file to `~/.claude/ide/[port].lock` with connection info
3. Sets environment variables that tell Claude where to connect
4. Implements MCP tools that Claude can call

For the full technical details and protocol documentation, see [PROTOCOL.md](./PROTOCOL.md).

📖 **[Read the full reverse-engineering story →](./STORY.md)**

## Architecture

Built with pure Lua and zero external dependencies:

- **WebSocket Server** - RFC 6455 compliant implementation using `vim.loop`
- **MCP Protocol** - Full JSON-RPC 2.0 message handling
- **Lock File System** - Enables Claude CLI discovery
- **Selection Tracking** - Real-time context updates
- **Native Diff Support** - Seamless file comparison

For deep technical details, see [ARCHITECTURE.md](./ARCHITECTURE.md).

## Contributing

See [DEVELOPMENT.md](./DEVELOPMENT.md) for build instructions and development guidelines. Tests can be run with `make test`.

## Advanced Setup

<details>
<summary>Full configuration with all options</summary>

```lua
{
  "coder/claudecode.nvim",
  dependencies = {
    "folke/snacks.nvim", -- Optional for enhanced terminal
  },
  opts = {
    -- Server options
    port_range = { min = 10000, max = 65535 },
    auto_start = true,
    log_level = "info",

    -- Terminal options
    terminal = {
      split_side = "right",
      split_width_percentage = 0.3,
      provider = "snacks", -- or "native"
    },

    -- Diff options
    diff_opts = {
      auto_close_on_accept = true,
      vertical_split = true,
    },
  },
  config = true,
  keys = {
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    { "<leader>ao", "<cmd>ClaudeCodeOpen<cr>", desc = "Open Claude" },
    { "<leader>ax", "<cmd>ClaudeCodeClose<cr>", desc = "Close Claude" },
  },
}
```

</details>

## Troubleshooting

- **Claude not connecting?** Check `:ClaudeCodeStatus` and verify lock file exists in `~/.claude/ide/`
- **Need debug logs?** Set `log_level = "debug"` in setup
- **Terminal issues?** Try `provider = "native"` if using snacks.nvim

## License

[MIT](LICENSE)

## Acknowledgements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) by Anthropic
- Inspired by analyzing the official VS Code extension
- Built with assistance from AI (how meta!)

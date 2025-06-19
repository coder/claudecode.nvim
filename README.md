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
    { "<leader>a", nil, desc = "AI/Claude Code" },
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil" },
    },
    -- Diff management
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
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

- `:ClaudeCode [arguments]` - Toggle the Claude Code terminal window (simple show/hide behavior)
- `:ClaudeCodeFocus [arguments]` - Smart focus/toggle Claude terminal (switches to terminal if not focused, hides if focused)
- `:ClaudeCode --resume` - Resume a previous Claude conversation
- `:ClaudeCode --continue` - Continue Claude conversation
- `:ClaudeCodeSend` - Send current visual selection to Claude, or add files from tree explorer
- `:ClaudeCodeTreeAdd` - Add selected file(s) from tree explorer to Claude context (also available via ClaudeCodeSend)
- `:ClaudeCodeAdd <file-path> [start-line] [end-line]` - Add a specific file or directory to Claude context by path with optional line range
- `:ClaudeCodeDiffAccept` - Accept the current diff changes (equivalent to `<leader>aa`)
- `:ClaudeCodeDiffDeny` - Deny/reject the current diff changes (equivalent to `<leader>ad`)

### Toggle Behavior

- **`:ClaudeCode`** - Simple toggle: Always show/hide terminal regardless of current focus
- **`:ClaudeCodeFocus`** - Smart focus: Focus terminal if not active, hide if currently focused

### Tree Integration

The `<leader>as` keybinding has context-aware behavior:

- **In normal buffers (visual mode)**: Sends selected text to Claude
- **In nvim-tree/neo-tree/oil.nvim buffers**: Adds the file under cursor (or selected files) to Claude's context

This allows you to quickly add entire files to Claude's context for review, refactoring, or discussion.

#### Features

- **Single file**: Place cursor on any file and press `<leader>as`
- **Multiple files**: Select multiple files (using tree plugin's selection features or visual selection in oil.nvim) and press `<leader>as`
- **Smart detection**: Automatically detects whether you're in nvim-tree, neo-tree, or oil.nvim
- **Error handling**: Clear feedback if no files are selected or if tree plugins aren't available

### Direct File Addition

The `:ClaudeCodeAdd` command allows you to add files or directories directly by path, with optional line range specification:

```vim
:ClaudeCodeAdd src/main.lua
:ClaudeCodeAdd ~/projects/myproject/
:ClaudeCodeAdd ./README.md
:ClaudeCodeAdd src/main.lua 50 100    " Lines 50-100 only
:ClaudeCodeAdd config.lua 25          " Only line 25
```

#### Features

- **Path completion**: Tab completion for file and directory paths
- **Path expansion**: Supports `~` for home directory and relative paths
- **Line range support**: Optionally specify start and end lines for files (ignored for directories)
- **Validation**: Checks that files and directories exist before adding, validates line numbers
- **Flexible**: Works with both individual files and entire directories

## Working with Diffs

When Claude proposes changes to your files, the plugin opens a native Neovim diff view showing the original file alongside the proposed changes. You have several options to accept or reject these changes:

### Accepting Changes

- **`:w` (save)** - Accept the changes and apply them to your file
- **`<leader>aa`** - Accept the changes using the dedicated keymap (configured in LazyVim spec)

You can edit the proposed changes in the right-hand diff buffer before accepting them. This allows you to modify Claude's suggestions or make additional tweaks before applying the final version to your file.

Both methods signal Claude Code to apply the changes to your file, after which the plugin automatically reloads the affected buffers to show the updated content.

### Rejecting Changes

- **`:q` or `:close`** - Close the diff view to reject the changes
- **`<leader>ad`** - Reject changes using the dedicated keymap (configured in LazyVim spec)
- **`:bdelete` or `:bwipeout`** - Delete the diff buffer to reject changes

When you reject changes, the diff view closes and the original file remains unchanged.

### Accepting/Rejecting from Claude Code Terminal

You can also navigate to the Claude Code terminal window and accept or reject diffs directly from within Claude's interface. This provides an alternative way to manage diffs without using the Neovim-specific keymaps.

### Customizing Diff Keymaps

The diff keymaps are configured in the LazyVim spec and can be customized by modifying the `keys` table:

```lua
{
  "coder/claudecode.nvim",
  config = true,
  keys = {
    -- ... other keymaps ...

    -- Customize diff keymaps to avoid conflicts (e.g., with debugger)
    { "<leader>ya", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>yn", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },

    -- Or disable them entirely by omitting them from the keys table
  },
}
```

The commands `ClaudeCodeDiffAccept` and `ClaudeCodeDiffDeny` work only in diff buffers created by the plugin and will show a warning if used elsewhere.

### How It Works

The plugin uses a signal-based approach where accepting or rejecting a diff sends a message to Claude Code rather than directly modifying files. This ensures consistency and allows Claude Code to handle the actual file operations while the plugin manages the user interface and buffer reloading.

#### Examples

```vim
" Add entire files
:ClaudeCodeAdd src/components/Header.tsx
:ClaudeCodeAdd ~/.config/nvim/init.lua

" Add entire directories (line numbers ignored)
:ClaudeCodeAdd tests/
:ClaudeCodeAdd ../other-project/

" Add specific line ranges
:ClaudeCodeAdd src/main.lua 50 100        " Lines 50 through 100
:ClaudeCodeAdd config.lua 25              " Only line 25
:ClaudeCodeAdd utils.py 1 50              " First 50 lines
:ClaudeCodeAdd README.md 10 20            " Just lines 10-20

" Path expansion works with line ranges
:ClaudeCodeAdd ~/project/src/app.js 100 200
:ClaudeCodeAdd ./relative/path.lua 30
```

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

## Configuration

### Quick Setup

For most users, the default configuration is sufficient:

```lua
{
  "coder/claudecode.nvim",
  dependencies = {
    "folke/snacks.nvim", -- optional
  },
  config = true,
  keys = {
    { "<leader>a", nil, desc = "AI/Claude Code" },
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil" },
    },
    -- Diff management
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
}
```

### Advanced Configuration

<details>
<summary>Complete configuration options</summary>

```lua
{
  "coder/claudecode.nvim",
  dependencies = {
    "folke/snacks.nvim", -- Optional for enhanced terminal
  },
  keys = {
    { "<leader>a", nil, desc = "AI/Claude Code" },
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil" },
    },
    -- Diff management
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
  opts = {
    -- Server Configuration
    port_range = { min = 10000, max = 65535 },  -- WebSocket server port range
    auto_start = true,                          -- Auto-start server on Neovim startup
    log_level = "info",                         -- "trace", "debug", "info", "warn", "error"
    terminal_cmd = nil,                         -- Custom terminal command (default: "claude")

    -- Selection Tracking
    track_selection = true,                     -- Enable real-time selection tracking
    visual_demotion_delay_ms = 50,             -- Delay before demoting visual selection (ms)

    -- Connection Management
    connection_wait_delay = 200,                -- Wait time after connection before sending queued @ mentions (ms)
    connection_timeout = 10000,                 -- Max time to wait for Claude Code connection (ms)
    queue_timeout = 5000,                       -- Max time to keep @ mentions in queue (ms)

    -- Terminal Configuration
    terminal = {
      split_side = "right",                     -- "left" or "right"
      split_width_percentage = 0.30,            -- Width as percentage (0.0 to 1.0)
      provider = "auto",                        -- "auto", "snacks", or "native"
      show_native_term_exit_tip = true,         -- Show exit tip for native terminal
      auto_close = true,                        -- Auto-close terminal after command completion
    },

    -- Diff Integration
    diff_opts = {
      auto_close_on_accept = true,              -- Close diff view after accepting changes
      show_diff_stats = true,                   -- Show diff statistics
      vertical_split = true,                    -- Use vertical split for diffs
      open_in_current_tab = true,               -- Open diffs in current tab vs new tab
    },
  },
}
```

</details>

### Configuration Options Explained

#### Server Options

- **`port_range`**: Port range for the WebSocket server that Claude connects to
- **`auto_start`**: Whether to automatically start the integration when Neovim starts
- **`terminal_cmd`**: Override the default "claude" command (useful for custom Claude installations)
- **`log_level`**: Controls verbosity of plugin logs

#### Selection Tracking

- **`track_selection`**: Enables real-time selection updates sent to Claude
- **`visual_demotion_delay_ms`**: Time to wait before switching from visual selection to cursor position tracking

#### Connection Management

- **`connection_wait_delay`**: Prevents overwhelming Claude with rapid @ mentions after connection
- **`connection_timeout`**: How long to wait for Claude to connect before giving up
- **`queue_timeout`**: How long to keep queued @ mentions before discarding them

#### Terminal Configuration

- **`split_side`**: Which side to open the terminal split (`"left"` or `"right"`)
- **`split_width_percentage`**: Terminal width as a fraction of screen width (0.1 = 10%, 0.5 = 50%)
- **`provider`**: Terminal implementation to use:
  - `"auto"`: Try snacks.nvim, fallback to native
  - `"snacks"`: Force snacks.nvim (requires folke/snacks.nvim)
  - `"native"`: Use built-in Neovim terminal
  - `"external"`: Use external terminal (e.g., tmux, separate terminal window)
- **`show_native_term_exit_tip`**: Show help text for exiting native terminal
- **`auto_close`**: Automatically close terminal when commands finish

#### Diff Options

- **`auto_close_on_accept`**: Close diff view after accepting changes with `:w` or `<leader>aa`
- **`show_diff_stats`**: Display diff statistics (lines added/removed)
- **`vertical_split`**: Use vertical split layout for diffs
- **`open_in_current_tab`**: Open diffs in current tab instead of creating new tabs

### Example Configurations

#### Minimal Configuration

```lua
{
  "coder/claudecode.nvim",
  keys = {
    { "<leader>a", nil, desc = "AI/Claude Code" },
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil" },
    },
    -- Diff management
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
  opts = {
    log_level = "warn",  -- Reduce log verbosity
    auto_start = false,  -- Manual startup only
  },
}
```

#### Power User Configuration

```lua
{
  "coder/claudecode.nvim",
  keys = {
    { "<leader>a", nil, desc = "AI/Claude Code" },
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil" },
    },
    -- Diff management
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
  opts = {
    log_level = "debug",
    visual_demotion_delay_ms = 100,  -- Slower selection demotion
    connection_wait_delay = 500,     -- Longer delay for @ mention batching
    terminal = {
      split_side = "left",
      split_width_percentage = 0.4,  -- Wider terminal
      provider = "snacks",
      auto_close = false,            -- Keep terminal open to review output
    },
    diff_opts = {
      vertical_split = false,        -- Horizontal diffs
      open_in_current_tab = false,   -- New tabs for diffs
    },
  },
}
```

#### External Terminal Configuration

If you prefer to run Claude Code in an external terminal (e.g., tmux, separate terminal window), configure the plugin to use the external provider and load on startup:

```lua
{
  "coder/claudecode.nvim",
  event = "VeryLazy",  -- Load on startup for auto-start behavior
  opts = {
    terminal = {
      provider = "external",  -- Don't launch internal terminals
    },
  },
  keys = {
    { "<leader>a", nil, desc = "AI/Claude Code" },
    -- Add any keymaps you want (but they're not required for loading)
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil" },
    },
    -- Diff management
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
}
```

With this configuration:

- The MCP server starts automatically when Neovim loads
- Run `claude --ide` in your external terminal to connect
- Use `:ClaudeCodeStatus` to check connection status and get guidance

#### Custom Claude Installation

```lua
{
  "coder/claudecode.nvim",
  keys = {
    { "<leader>a", nil, desc = "AI/Claude Code" },
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil" },
    },
    -- Diff management
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
  opts = {
    terminal_cmd = "/opt/claude/bin/claude",  -- Custom Claude path
    port_range = { min = 20000, max = 25000 }, -- Different port range
  },
}
```

## Troubleshooting

- **Claude not connecting?** Check `:ClaudeCodeStatus` and verify lock file exists in `~/.claude/ide/`
- **Need debug logs?** Set `log_level = "debug"` in setup
- **Terminal issues?** Try `provider = "native"` if using snacks.nvim
- **Auto-start not working?** If using external terminal provider, ensure you're using `event = "VeryLazy"` instead of `keys = {...}` only, as lazy loading prevents auto-start from running

## License

[MIT](LICENSE)

## Acknowledgements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) by Anthropic
- Inspired by analyzing the official VS Code extension
- Built with assistance from AI (how meta!)

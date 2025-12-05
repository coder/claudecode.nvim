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

## Installation

```lua
{
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  config = true,
  keys = {
    { "<leader>a", nil, desc = "AI/Claude Code" },
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>am", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },
    { "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
    },
    -- Diff management
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
}
```

That's it! The plugin will auto-configure everything else.

## Requirements

- Neovim >= 0.8.0
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim) for enhanced terminal support

## Local Installation Configuration

If you've used Claude Code's `migrate-installer` command to move to a local installation, you'll need to configure the plugin to use the local path.

### What is a Local Installation?

Claude Code offers a `claude migrate-installer` command that:

- Moves Claude Code from a global npm installation to `~/.claude/local/`
- Avoids permission issues with system directories
- Creates shell aliases but these may not be available to Neovim

### Detecting Your Installation Type

Check your installation type:

```bash
# Check where claude command points
which claude

# Global installation shows: /usr/local/bin/claude (or similar)
# Local installation shows: alias to ~/.claude/local/claude

# Verify installation health
claude doctor
```

### Configuring for Local Installation

If you have a local installation, configure the plugin with the direct path:

```lua
{
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {
    terminal_cmd = "~/.claude/local/claude", -- Point to local installation
  },
  config = true,
  keys = {
    -- Your keymaps here
  },
}
```

<details>
<summary>Native Binary Installation (Alpha)</summary>

Claude Code also offers an experimental native binary installation method currently in alpha testing. This provides a single executable with no Node.js dependencies.

#### Installation Methods

Install the native binary using one of these methods:

```bash
# Fresh install (recommended)
curl -fsSL claude.ai/install.sh | bash

# From existing Claude Code installation
claude install
```

#### Platform Support

- **macOS**: Full support for Intel and Apple Silicon
- **Linux**: x64 and arm64 architectures
- **Windows**: Via WSL (Windows Subsystem for Linux)

#### Benefits

- **Zero Dependencies**: Single executable file with no external requirements
- **Cross-Platform**: Consistent experience across operating systems
- **Secure Installation**: Includes checksum verification and automatic cleanup

#### Configuring for Native Binary

The exact binary path depends on your shell integration. To find your installation:

```bash
# Check where claude command points
which claude

# Verify installation type and health
claude doctor
```

Configure the plugin with the detected path:

```lua
{
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {
    terminal_cmd = "/path/to/your/claude", -- Use output from 'which claude'
  },
  config = true,
  keys = {
    -- Your keymaps here
  },
}
```

</details>

> **Note**: If Claude Code was installed globally via npm, you can use the default configuration without specifying `terminal_cmd`.

## Quick Demo

```vim
" Launch Claude Code in a split
:ClaudeCode

" Claude now sees your current file and selections in real-time!

" Send visual selection as context
:'<,'>ClaudeCodeSend

" Claude can open files, show diffs, and more
```

## Usage

1. **Launch Claude**: Run `:ClaudeCode` to open Claude in a split terminal
2. **Send context**:
   - Select text in visual mode and use `<leader>as` to send it to Claude
   - In `nvim-tree`/`neo-tree`/`oil.nvim`/`mini.nvim`, press `<leader>as` on a file to add it to Claude's context
3. **Let Claude work**: Claude can now:
   - See your current file and selections in real-time
   - Open files in your editor
   - Show diffs with proposed changes
   - Access diagnostics and workspace info

## Key Commands

- `:ClaudeCode` - Toggle the Claude Code terminal window
- `:ClaudeCodeFocus` - Smart focus/toggle Claude terminal
- `:ClaudeCodeSelectModel` - Select Claude model and open terminal with optional arguments
- `:ClaudeCodeSend` - Send current visual selection to Claude
- `:ClaudeCodeAdd <file-path> [start-line] [end-line]` - Add specific file to Claude context with optional line range
- `:ClaudeCodeDiffAccept` - Accept diff changes
- `:ClaudeCodeDiffDeny` - Reject diff changes

## Working with Diffs

When Claude proposes changes, the plugin opens a native Neovim diff view:

- **Accept**: `:w` (save) or `<leader>aa`
- **Reject**: `:q` or `<leader>ad`

You can edit Claude's suggestions before accepting them.

## How It Works

This plugin creates a WebSocket server that Claude Code CLI connects to, implementing the same protocol as the official VS Code extension. When you launch Claude, it automatically detects Neovim and gains full access to your editor.

The protocol uses a WebSocket-based variant of MCP (Model Context Protocol) that:

1. Creates a WebSocket server on a random port
2. Writes a lock file to `~/.claude/ide/[port].lock` (or `$CLAUDE_CONFIG_DIR/ide/[port].lock` if `CLAUDE_CONFIG_DIR` is set) with connection info
3. Sets environment variables that tell Claude where to connect
4. Implements MCP tools that Claude can call

📖 **[Read the full reverse-engineering story →](./STORY.md)**
🔧 **[Complete protocol documentation →](./PROTOCOL.md)**

## Architecture

Built with pure Lua and zero external dependencies:

- **WebSocket Server** - RFC 6455 compliant implementation using `vim.loop`
- **MCP Protocol** - Full JSON-RPC 2.0 message handling
- **Lock File System** - Enables Claude CLI discovery
- **Selection Tracking** - Real-time context updates
- **Native Diff Support** - Seamless file comparison

For deep technical details, see [ARCHITECTURE.md](./ARCHITECTURE.md).

## Advanced Configuration

```lua
{
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {
    -- Server Configuration
    port_range = { min = 10000, max = 65535 },
    auto_start = true,
    log_level = "info", -- "trace", "debug", "info", "warn", "error"
    terminal_cmd = nil, -- Custom terminal command (default: "claude")
                        -- For local installations: "~/.claude/local/claude"
                        -- For native binary: use output from 'which claude'

    -- Send/Focus Behavior
    -- When true, successful sends will focus the Claude terminal if already connected
    focus_after_send = false,

    -- Selection Tracking
    track_selection = true,
    visual_demotion_delay_ms = 50,

    -- Terminal Configuration
    terminal = {
      split_side = "right", -- "left" or "right"
      split_width_percentage = 0.30,
      provider = "auto", -- "auto", "snacks", "native", "external", "none", or custom provider table
      auto_close = true,
      snacks_win_opts = {}, -- Opts to pass to `Snacks.terminal.open()` - see Floating Window section below

      -- Provider-specific options
      provider_opts = {
        -- Command for external terminal provider. Can be:
        -- 1. String with %s placeholder: "alacritty -e %s" (backward compatible)
        -- 2. String with two %s placeholders: "alacritty --working-directory %s -e %s" (cwd, command)
        -- 3. Function returning command: function(cmd, env) return "alacritty -e " .. cmd end
        external_terminal_cmd = nil,
      },
    },

    -- Diff Integration
    diff_opts = {
      auto_close_on_accept = true,
      vertical_split = true,
      open_in_current_tab = true,
      keep_terminal_focus = false, -- If true, moves focus back to terminal after diff opens
    },
  },
  keys = {
    -- Your keymaps here
  },
}
```

### Working Directory Control

You can fix the Claude terminal's working directory regardless of `autochdir` and buffer-local cwd changes. Options (precedence order):

- `cwd_provider(ctx)`: function that returns a directory string. Receives `{ file, file_dir, cwd }`.
- `cwd`: static path to use as working directory.
- `git_repo_cwd = true`: resolves git root from the current file directory (or cwd if no file).

Examples:

```lua
require("claudecode").setup({
  -- Top-level aliases are supported and forwarded to terminal config
  git_repo_cwd = true,
})

require("claudecode").setup({
  terminal = {
    cwd = vim.fn.expand("~/projects/my-app"),
  },
})

require("claudecode").setup({
  terminal = {
    cwd_provider = function(ctx)
      -- Prefer repo root; fallback to file's directory
      local cwd = require("claudecode.cwd").git_root(ctx.file_dir or ctx.cwd) or ctx.file_dir or ctx.cwd
      return cwd
    end,
  },
})
```

## Floating Window Configuration

The `snacks_win_opts` configuration allows you to create floating Claude Code terminals with custom positioning, sizing, and key bindings. Here are several practical examples:

### Basic Floating Window with Ctrl+, Toggle

```lua
local toggle_key = "<C-,>"
return {
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    keys = {
      { toggle_key, "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code", mode = { "n", "x" } },
    },
    opts = {
      terminal = {
        ---@module "snacks"
        ---@type snacks.win.Config|{}
        snacks_win_opts = {
          position = "float",
          width = 0.9,
          height = 0.9,
          keys = {
            claude_hide = {
              toggle_key,
              function(self)
                self:hide()
              end,
              mode = "t",
              desc = "Hide",
            },
          },
        },
      },
    },
  },
}
```

<details>
<summary>Alternative with Meta+, (Alt+,) Toggle</summary>

```lua
local toggle_key = "<M-,>"  -- Alt/Meta + comma
return {
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    keys = {
      { toggle_key, "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code", mode = { "n", "x" } },
    },
    opts = {
      terminal = {
        snacks_win_opts = {
          position = "float",
          width = 0.8,
          height = 0.8,
          border = "rounded",
          keys = {
            claude_hide = { toggle_key, function(self) self:hide() end, mode = "t", desc = "Hide" },
          },
        },
      },
    },
  },
}
```

</details>

<details>
<summary>Centered Floating Window with Custom Styling</summary>

```lua
require("claudecode").setup({
  terminal = {
    snacks_win_opts = {
      position = "float",
      width = 0.6,
      height = 0.6,
      border = "double",
      backdrop = 80,
      keys = {
        claude_hide = { "<Esc>", function(self) self:hide() end, mode = "t", desc = "Hide" },
        claude_close = { "q", "close", mode = "n", desc = "Close" },
      },
    },
  },
})
```

</details>

<details>
<summary>Multiple Key Binding Options</summary>

```lua
{
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  keys = {
    { "<C-,>", "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code (Ctrl+,)", mode = { "n", "x" } },
    { "<M-,>", "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code (Alt+,)", mode = { "n", "x" } },
    { "<leader>tc", "<cmd>ClaudeCodeFocus<cr>", desc = "Toggle Claude", mode = { "n", "x" } },
  },
  opts = {
    terminal = {
      snacks_win_opts = {
        position = "float",
        width = 0.85,
        height = 0.85,
        border = "rounded",
        keys = {
          -- Multiple ways to hide from terminal mode
          claude_hide_ctrl = { "<C-,>", function(self) self:hide() end, mode = "t", desc = "Hide (Ctrl+,)" },
          claude_hide_alt = { "<M-,>", function(self) self:hide() end, mode = "t", desc = "Hide (Alt+,)" },
          claude_hide_esc = { "<C-\\><C-n>", function(self) self:hide() end, mode = "t", desc = "Hide (Ctrl+\\)" },
        },
      },
    },
  },
}
```

</details>

<details>
<summary>Window Position Variations</summary>

```lua
-- Bottom floating (like a drawer)
snacks_win_opts = {
  position = "bottom",
  height = 0.4,
  width = 1.0,
  border = "single",
}

-- Side floating panel
snacks_win_opts = {
  position = "right",
  width = 0.4,
  height = 1.0,
  border = "rounded",
}

-- Small centered popup
snacks_win_opts = {
  position = "float",
  width = 120,  -- Fixed width in columns
  height = 30,  -- Fixed height in rows
  border = "double",
  backdrop = 90,
}
```

</details>

For complete configuration options, see:

- [Snacks.nvim Terminal Documentation](https://github.com/folke/snacks.nvim/blob/main/docs/terminal.md)
- [Snacks.nvim Window Documentation](https://github.com/folke/snacks.nvim/blob/main/docs/win.md)

## Terminal Providers

### None (No-Op) Provider

Run Claude Code without any terminal management inside Neovim. This is useful for advanced setups where you manage the CLI externally (tmux, kitty, separate terminal windows) while still using the WebSocket server and tools.

You have to take care of launching CC and connecting it to the IDE yourself. (e.g. `claude --ide` or launching claude and then selecting the IDE using the `/ide` command)

```lua
{
  "coder/claudecode.nvim",
  opts = {
    terminal = {
      provider = "none", -- no UI actions; server + tools remain available
    },
  },
}
```

Notes:

- No windows/buffers are created. `:ClaudeCode` and related commands will not open anything.
- The WebSocket server still starts and broadcasts work as usual. Launch the Claude CLI externally when desired.

### External Terminal Provider

Run Claude Code in a separate terminal application outside of Neovim:

```lua
-- Using a string template (simple)
{
  "coder/claudecode.nvim",
  opts = {
    terminal = {
      provider = "external",
      provider_opts = {
        external_terminal_cmd = "alacritty -e %s", -- %s is replaced with claude command
        -- Or with working directory: "alacritty --working-directory %s -e %s" (first %s = cwd, second %s = command)
      },
    },
  },
}

-- Using a function for dynamic command generation (advanced)
{
  "coder/claudecode.nvim",
  opts = {
    terminal = {
      provider = "external",
      provider_opts = {
        external_terminal_cmd = function(cmd, env)
          -- You can build complex commands based on environment or conditions
          if vim.fn.has("mac") == 1 then
            return { "osascript", "-e", string.format('tell app "Terminal" to do script "%s"', cmd) }
          else
            return "alacritty -e " .. cmd
          end
        end,
      },
    },
  },
}
```

### Custom Terminal Providers

You can create custom terminal providers by passing a table with the required functions instead of a string provider name:

```lua
require("claudecode").setup({
  terminal = {
    provider = {
      -- Required functions
      setup = function(config)
        -- Initialize your terminal provider
      end,

      open = function(cmd_string, env_table, effective_config, focus)
        -- Open terminal with command and environment
        -- focus parameter controls whether to focus terminal (defaults to true)
      end,

      close = function()
        -- Close the terminal
      end,

      simple_toggle = function(cmd_string, env_table, effective_config)
        -- Simple show/hide toggle
      end,

      focus_toggle = function(cmd_string, env_table, effective_config)
        -- Smart toggle: focus terminal if not focused, hide if focused
      end,

      get_active_bufnr = function()
        -- Return terminal buffer number or nil
        return 123 -- example
      end,

      is_available = function()
        -- Return true if provider can be used
        return true
      end,

      -- Optional functions (auto-generated if not provided)
      toggle = function(cmd_string, env_table, effective_config)
        -- Defaults to calling simple_toggle for backward compatibility
      end,

      _get_terminal_for_test = function()
        -- For testing only, defaults to return nil
        return nil
      end,
    },
  },
})
```

### Custom Provider Example

Here's a complete example using a hypothetical `my_terminal` plugin:

```lua
local my_terminal_provider = {
  setup = function(config)
    -- Store config for later use
    self.config = config
  end,

  open = function(cmd_string, env_table, effective_config, focus)
    if focus == nil then focus = true end

    local my_terminal = require("my_terminal")
    my_terminal.open({
      cmd = cmd_string,
      env = env_table,
      width = effective_config.split_width_percentage,
      side = effective_config.split_side,
      focus = focus,
    })
  end,

  close = function()
    require("my_terminal").close()
  end,

  simple_toggle = function(cmd_string, env_table, effective_config)
    require("my_terminal").toggle()
  end,

  focus_toggle = function(cmd_string, env_table, effective_config)
    local my_terminal = require("my_terminal")
    if my_terminal.is_focused() then
      my_terminal.hide()
    else
      my_terminal.focus()
    end
  end,

  get_active_bufnr = function()
    return require("my_terminal").get_bufnr()
  end,

  is_available = function()
    local ok, _ = pcall(require, "my_terminal")
    return ok
  end,
}

require("claudecode").setup({
  terminal = {
    provider = my_terminal_provider,
  },
})
```

The custom provider will automatically fall back to the native provider if validation fails or `is_available()` returns false.

Note: If your command or working directory may contain spaces or special characters, prefer returning a table of args from a function (e.g., `{ "alacritty", "--working-directory", cwd, "-e", "claude", "--help" }`) to avoid shell-quoting issues.

## Community Extensions

The following are third-party community extensions that complement claudecode.nvim. **These extensions are not affiliated with Coder and are maintained independently by community members.** We do not ensure that these extensions work correctly or provide support for them.

### 🔍 [claude-fzf.nvim](https://github.com/pittcat/claude-fzf.nvim)

Integrates fzf-lua's file selection with claudecode.nvim's context management:

- Batch file selection with fzf-lua multi-select
- Smart search integration with grep → Claude
- Tree-sitter based context extraction
- Support for files, buffers, git files

### 📚 [claude-fzf-history.nvim](https://github.com/pittcat/claude-fzf-history.nvim)

Provides convenient Claude interaction history management and access for enhanced workflow continuity.

> **Disclaimer**: These community extensions are developed and maintained by independent contributors. The authors and their extensions are not affiliated with Coder. Use at your own discretion and refer to their respective repositories for installation instructions, documentation, and support.

## Auto-Save Plugin Issues

Using auto-save plugins can cause diff windows opened by Claude to immediately accept without waiting for input. You can avoid this using a custom condition:

<details>
<summary>Pocco81/auto-save.nvim</summary>

```lua
opts = {
  -- ... other options
  condition = function(buf)
    local fn = vim.fn
    local utils = require("auto-save.utils.data")

    -- First check the default conditions
    if not (fn.getbufvar(buf, "&modifiable") == 1 and utils.not_in(fn.getbufvar(buf, "&filetype"), {})) then
      return false
    end

    -- Exclude claudecode diff buffers by buffer name patterns
    local bufname = vim.api.nvim_buf_get_name(buf)
    if bufname:match("%(proposed%)") or
       bufname:match("%(NEW FILE %- proposed%)") or
       bufname:match("%(New%)") then
      return false
    end

    -- Exclude by buffer variables (claudecode sets these)
    if vim.b[buf].claudecode_diff_tab_name or
       vim.b[buf].claudecode_diff_new_win or
       vim.b[buf].claudecode_diff_target_win then
      return false
    end

    -- Exclude by buffer type (claudecode diff buffers use "acwrite")
    local buftype = fn.getbufvar(buf, "&buftype")
    if buftype == "acwrite" then
      return false
    end

    return true -- Safe to auto-save
  end,
},
```

</details>
<details>
<summary>okuuva/auto-save.nvim</summary>

```lua
opts = {
  -- ... other options
  condition = function(buf)
    -- Exclude claudecode diff buffers by buffer name patterns
    local bufname = vim.api.nvim_buf_get_name(buf)
    if bufname:match('%(proposed%)') or bufname:match('%(NEW FILE %- proposed%)') or bufname:match('%(New%)') then
      return false
    end

    -- Exclude by buffer variables (claudecode sets these)
    if
      vim.b[buf].claudecode_diff_tab_name
      or vim.b[buf].claudecode_diff_new_win
      or vim.b[buf].claudecode_diff_target_win
    then
      return false
    end

    -- Exclude by buffer type (claudecode diff buffers use "acwrite")
    local buftype = vim.fn.getbufvar(buf, '&buftype')
    if buftype == 'acwrite' then
      return false
    end

    return true -- Safe to auto-save
  end,
},
```

</details>

## Troubleshooting

- **Claude not connecting?** Check `:ClaudeCodeStatus` and verify lock file exists in `~/.claude/ide/` (or `$CLAUDE_CONFIG_DIR/ide/` if `CLAUDE_CONFIG_DIR` is set)
- **Need debug logs?** Set `log_level = "debug"` in opts
- **Terminal issues?** Try `provider = "native"` if using snacks.nvim
- **Local installation not working?** If you used `claude migrate-installer`, set `terminal_cmd = "~/.claude/local/claude"` in your config. Check `which claude` vs `ls ~/.claude/local/claude` to verify your installation type.
- **Native binary installation not working?** If you used the alpha native binary installer, run `claude doctor` to verify installation health and use `which claude` to find the binary path. Set `terminal_cmd = "/path/to/claude"` with the detected path in your config.

## Contributing

See [DEVELOPMENT.md](./DEVELOPMENT.md) for build instructions and development guidelines. Tests can be run with `make test`.

## License

[MIT](LICENSE)

## Acknowledgements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) by Anthropic
- Inspired by analyzing the official VS Code extension
- Built with assistance from AI (how meta!)

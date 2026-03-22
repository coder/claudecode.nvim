# opencode.nvim

[![Tests](https://github.com/lanjoni/opencode.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/lanjoni/opencode.nvim/actions/workflows/test.yml)
![Neovim version](https://img.shields.io/badge/Neovim-0.8%2B-green)
![Status](https://img.shields.io/badge/Status-beta-blue)

**The first Neovim IDE integration for OpenCode** — bringing Anthropic's AI coding assistant to your favorite editor with a pure Lua implementation.

> 🎯 **TL;DR:** When Anthropic released OpenCode with VS Code and JetBrains support, I reverse-engineered their extension and built this Neovim plugin. This plugin implements the same WebSocket-based MCP protocol, giving Neovim users the same AI-powered coding experience.

<https://github.com/user-attachments/assets/9c310fb5-5a23-482b-bedc-e21ae457a82d>

## What Makes This Special

When Anthropic released OpenCode, they only supported VS Code and JetBrains. As a Neovim user, I wanted the same experience — so I reverse-engineered their extension and built this.

- 🚀 **Pure Lua, Zero Dependencies** — Built entirely with `vim.loop` and Neovim built-ins
- 🔌 **100% Protocol Compatible** — Same WebSocket MCP implementation as official extensions
- 🎓 **Fully Documented Protocol** — Learn how to build your own integrations ([see PROTOCOL.md](./PROTOCOL.md))
- ⚡ **First to Market** — Beat Anthropic to releasing Neovim support
- 🛠️ **Built with AI** — Used OpenCode to reverse-engineer OpenCode's own protocol

## Installation

```lua
{
  "lanjoni/opencode.nvim",
  dependencies = { "folke/snacks.nvim" },
  config = true,
  keys = {
    { "<leader>a", nil, desc = "AI/OpenCode" },
    { "<leader>ac", "<cmd>OpenCode<cr>", desc = "Toggle OpenCode" },
    { "<leader>af", "<cmd>OpenCodeFocus<cr>", desc = "Focus OpenCode" },
    { "<leader>ar", "<cmd>OpenCode --resume<cr>", desc = "Resume OpenCode" },
    { "<leader>aC", "<cmd>OpenCode --continue<cr>", desc = "Continue OpenCode" },
    { "<leader>ab", "<cmd>OpenCodeAdd %<cr>", desc = "Add current buffer" },
    { "<leader>as", "<cmd>OpenCodeSend<cr>", mode = "v", desc = "Send to OpenCode" },
    {
      "<leader>as",
      "<cmd>OpenCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
    },
    -- Diff management
    { "<leader>aa", "<cmd>OpenCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>OpenCodeDiffDeny<cr>", desc = "Deny diff" },
  },
}
```

That's it! The plugin will auto-configure everything else.

## Requirements

- Neovim >= 0.8.0
- [OpenCode CLI](https://opencode.ai/docs/) installed (default)
- [OpenCode CLI](https://docs.anthropic.com/en/docs/claude-code) (optional, when `terminal_cmd` is set to `claude`)
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim) for enhanced terminal support

## Local Installation Configuration

If you've used OpenCode's `migrate-installer` command to move to a local installation, you'll need to configure the plugin to use the local path.

### What is a Local Installation?

OpenCode offers a `opencode install` command that:

- Moves OpenCode from a global npm installation to `~/.opencode/local/`
- Avoids permission issues with system directories
- Creates shell aliases but these may not be available to Neovim

### Detecting Your Installation Type

Check your installation type:

```bash
# Check where opencode command points
which opencode

# Global installation shows: /usr/local/bin/opencode (or similar)
# Local installation shows: alias to ~/.opencode/local/claude

# Verify installation health
opencode doctor
```

### Configuring for Local Installation

If you have a local installation, configure the plugin with the direct path:

```lua
{
  "lanjoni/opencode.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {
    terminal_cmd = "~/.opencode/local/opencode", -- Point to local installation
  },
  config = true,
  keys = {
    -- Your keymaps here
  },
}
```

<details>
<summary>Native Binary Installation (Alpha)</summary>

OpenCode also offers an experimental native binary installation method currently in alpha testing. This provides a single executable with no Node.js dependencies.

#### Installation Methods

Install the native binary using one of these methods:

```bash
# Fresh install (recommended)
curl -fsSL opencode.ai/install | bash

# From existing OpenCode installation
opencode install
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
# Check where opencode command points
which opencode

# Verify installation type and health
opencode doctor
```

Configure the plugin with the detected path:

```lua
{
  "lanjoni/opencode.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {
    terminal_cmd = "/path/to/your/opencode", -- Use output from 'which opencode'
  },
  config = true,
  keys = {
    -- Your keymaps here
  },
}
```

</details>

> **Note**: If OpenCode was installed globally via npm, you can use the default configuration without specifying `terminal_cmd`.

## Quick Demo

```vim
" Launch OpenCode in a split
:OpenCode

" OpenCode now sees your current file and selections in real-time!

" Send visual selection as context
:'<,'>OpenCodeSend

" OpenCode can open files, show diffs, and more
```

## Usage

1. **Launch OpenCode**: Run `:OpenCode` to open OpenCode in a split terminal
2. **Send context**:
   - Select text in visual mode and use `<leader>as` to send it to OpenCode
   - In `nvim-tree`/`neo-tree`/`oil.nvim`/`mini.nvim`, press `<leader>as` on a file to add it to OpenCode's context
3. **Let OpenCode work**: OpenCode can now:
   - See your current file and selections in real-time
   - Open files in your editor
   - Show diffs with proposed changes
   - Access diagnostics and workspace info

## Key Commands

- `:OpenCode` - Toggle the OpenCode terminal window
- `:OpenCodeFocus` - Smart focus/toggle OpenCode terminal
- `:OpenCodeSend` - Send current visual selection to OpenCode
- `:OpenCodeAdd <file-path> [start-line] [end-line]` - Add specific file to OpenCode context with optional line range
- `:OpenCodeDiffAccept` - Accept diff changes
- `:OpenCodeDiffDeny` - Reject diff changes

## Working with Diffs

When OpenCode proposes changes, the plugin opens a native Neovim diff view:

- **Accept**: `:w` (save) or `<leader>aa`
- **Reject**: `:q` or `<leader>ad`

You can edit OpenCode's suggestions before accepting them.

## How It Works

This plugin integrates with OpenCode using terminal-based communication. When you launch OpenCode, the plugin opens it in a dedicated terminal and communicates via stdin injection.

### Current Implementation (Terminal-Based)

1. **Terminal Launch**: Opens OpenCode in a split terminal with `--port` flag for HTTP API access
2. **Autocomplete Simulation**: Sends `@filename` via terminal input to trigger OpenCode's autocomplete
3. **File References**: Selects files from autocomplete to create styled file parts
4. **Context Sharing**: Sends visual selections and file references directly to the prompt

### WIP: Future WebSocket/SSE Support

When OpenCode implements proper IDE integration API:
- WebSocket or SSE for bidirectional communication
- Structured message support (FilePart, AgentPart, etc.)
- Lock file system at `~/.opencode/ide/[port].lock`
- MCP tool implementation

The current terminal-based approach provides immediate functionality while we await official API support from OpenCode.

📖 **[Read the full reverse-engineering story →](./STORY.md)**
🔧 **[Complete protocol documentation →](./PROTOCOL.md)**

## Architecture

Built with pure Lua and zero external dependencies:

- **Terminal Integration** - Direct terminal control with `jobstart()` and stdin injection
- **Autocomplete Simulation** - Triggers OpenCode's TUI autocomplete via keystrokes
- **Port Management** - HTTP API port tracking for future enhancements
- **Selection Tracking** - Real-time context updates
- **Native Diff Support** - Seamless file comparison
- **WIP: WebSocket Server** - RFC 6455 compliant implementation (for future OpenCode API)

For deep technical details, see [ARCHITECTURE.md](./ARCHITECTURE.md).

## Advanced Configuration

```lua
{
  "lanjoni/opencode.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {
    -- Server Configuration
    port_range = { min = 10000, max = 65535 },
    auto_start = true,
    log_level = "info", -- "trace", "debug", "info", "warn", "error"
    terminal_cmd = nil, -- Custom terminal command (default: "opencode")
                        -- For local installations: "~/.opencode/local/opencode"
                        -- For native binary: use output from 'which opencode'

    -- Send/Focus Behavior
    -- When true, successful sends will focus the OpenCode terminal if already connected
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
      layout = "vertical", -- "vertical" or "horizontal"
      open_in_new_tab = false,
      keep_terminal_focus = false, -- If true, moves focus back to terminal after diff opens
      hide_terminal_in_new_tab = false,
      -- on_new_file_reject = "keep_empty", -- "keep_empty" or "close_window"

      -- Legacy aliases (still supported):
      -- vertical_split = true,
      -- open_in_current_tab = true,
    },
  },
  keys = {
    -- Your keymaps here
  },
}
```

### Working Directory Control

You can fix the OpenCode terminal's working directory regardless of `autochdir` and buffer-local cwd changes. Options (precedence order):

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

The `snacks_win_opts` configuration allows you to create floating OpenCode terminals with custom positioning, sizing, and key bindings. Here are several practical examples:

### Basic Floating Window with Ctrl+, Toggle

```lua
local toggle_key = "<C-,>"
return {
  {
    "lanjoni/opencode.nvim",
    dependencies = { "folke/snacks.nvim" },
    keys = {
      { toggle_key, "<cmd>OpenCodeFocus<cr>", desc = "OpenCode", mode = { "n", "x" } },
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
    "lanjoni/opencode.nvim",
    dependencies = { "folke/snacks.nvim" },
    keys = {
      { toggle_key, "<cmd>OpenCodeFocus<cr>", desc = "OpenCode", mode = { "n", "x" } },
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
  "lanjoni/opencode.nvim",
  dependencies = { "folke/snacks.nvim" },
  keys = {
    { "<C-,>", "<cmd>OpenCodeFocus<cr>", desc = "OpenCode (Ctrl+,)", mode = { "n", "x" } },
    { "<M-,>", "<cmd>OpenCodeFocus<cr>", desc = "OpenCode (Alt+,)", mode = { "n", "x" } },
    { "<leader>tc", "<cmd>OpenCodeFocus<cr>", desc = "Toggle OpenCode", mode = { "n", "x" } },
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

Run OpenCode without any terminal management inside Neovim. This is useful for advanced setups where you manage the CLI externally (tmux, kitty, separate terminal windows) while still using the WebSocket server and tools.

You have to take care of launching CC and connecting it to the IDE yourself. (e.g. `opencode --ide` or launching opencode and then selecting the IDE using the `/ide` command)

```lua
{
  "lanjoni/opencode.nvim",
  opts = {
    terminal = {
      provider = "none", -- no UI actions; server + tools remain available
    },
  },
}
```

Notes:

- No windows/buffers are created. `:OpenCode` and related commands will not open anything.
- The WebSocket server still starts and broadcasts work as usual. Launch the OpenCode CLI externally when desired.

### External Terminal Provider

Run OpenCode in a separate terminal application outside of Neovim:

```lua
-- Using a string template (simple)
{
  "lanjoni/opencode.nvim",
  opts = {
    terminal = {
      provider = "external",
      provider_opts = {
        external_terminal_cmd = "alacritty -e %s", -- %s is replaced with opencode command
        -- Or with working directory: "alacritty --working-directory %s -e %s" (first %s = cwd, second %s = command)
      },
    },
  },
}

-- Using a function for dynamic command generation (advanced)
{
  "lanjoni/opencode.nvim",
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

Note: If your command or working directory may contain spaces or special characters, prefer returning a table of args from a function (e.g., `{ "alacritty", "--working-directory", cwd, "-e", "opencode", "--help" }`) to avoid shell-quoting issues.

## Community Extensions

The following are third-party community extensions that complement claudecode.nvim. **These extensions are not affiliated with Coder and are maintained independently by community members.** We do not ensure that these extensions work correctly or provide support for them.

### 🔍 [claude-fzf.nvim](https://github.com/pittcat/claude-fzf.nvim)

Integrates fzf-lua's file selection with claudecode.nvim's context management:

- Batch file selection with fzf-lua multi-select
- Smart search integration with grep → OpenCode
- Tree-sitter based context extraction
- Support for files, buffers, git files

### 📚 [claude-fzf-history.nvim](https://github.com/pittcat/claude-fzf-history.nvim)

Provides convenient OpenCode interaction history management and access for enhanced workflow continuity.

> **Disclaimer**: These community extensions are developed and maintained by independent contributors. The authors and their extensions are not affiliated with Coder. Use at your own discretion and refer to their respective repositories for installation instructions, documentation, and support.

## Auto-Save Plugin Issues

Using auto-save plugins can cause diff windows opened by OpenCode to immediately accept without waiting for input. You can avoid this using a custom condition:

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

- **OpenCode not connecting?** Check `:OpenCodeStatus` and verify lock file exists in `~/.opencode/ide/` (or `$OPENCODE_CONFIG_DIR/ide/` if `CLAUDE_CONFIG_DIR` is set)
- **Need debug logs?** Set `log_level = "debug"` in opts
- **Terminal issues?** Try `provider = "native"` if using snacks.nvim
- **Local installation not working?** If you used `opencode install`, set `terminal_cmd = "~/.opencode/local/opencode"` in your config. Check `which opencode` vs `ls ~/.opencode/local/claude` to verify your installation type.
- **Native binary installation not working?** If you used the alpha native binary installer, run `opencode doctor` to verify installation health and use `which opencode` to find the binary path. Set `terminal_cmd = "/path/to/opencode"` with the detected path in your config.

## Contributing

See [DEVELOPMENT.md](./DEVELOPMENT.md) for build instructions and development guidelines. Tests can be run with `make test`.

## License

[MIT](LICENSE)

## Acknowledgements

- [OpenCode CLI](https://docs.anthropic.com/en/docs/claude-code) by Anthropic
- Inspired by analyzing the official VS Code extension
- Built with assistance from AI (how meta!)

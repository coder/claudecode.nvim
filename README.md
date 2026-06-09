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
  -- `cmd` lets lazy.nvim create command stubs that load the plugin on first use,
  -- so `:ClaudeCode` and friends work on a fresh start. Without it, a keys-only
  -- spec defers loading until a <leader>a* mapping is pressed and the commands
  -- would not exist yet.
  cmd = {
    "ClaudeCode",
    "ClaudeCodeFocus",
    "ClaudeCodeSelectModel",
    "ClaudeCodeAdd",
    "ClaudeCodeSend",
    "ClaudeCodeTreeAdd",
    "ClaudeCodeStatus",
    "ClaudeCodeStart",
    "ClaudeCodeStop",
    "ClaudeCodeOpen",
    "ClaudeCodeClose",
    "ClaudeCodeDiffAccept",
    "ClaudeCodeDiffDeny",
    "ClaudeCodeCloseAllDiffs",
  },
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
      ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw", "snacks_picker_list" },
    },
    -- Diff management
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
}
```

That's it! The plugin will auto-configure everything else.

> **Lazy-loading:** with this spec the plugin loads on first use — when a listed
> `cmd` is run or a mapped key is pressed — not at startup. The `cmd` list is what
> makes `:ClaudeCode` (and the other commands below) available before any keymap is
> pressed. If you would rather load the plugin eagerly at startup, set `lazy = false`
> (the `cmd`/`keys` triggers then become optional).

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
  -- Also copy the `cmd = { ... }` list from the Installation section above so the
  -- :ClaudeCode* commands load without having to press a key first.
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
  -- Also copy the `cmd = { ... }` list from the Installation section above so the
  -- :ClaudeCode* commands load without having to press a key first.
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
   - In `nvim-tree`/`neo-tree`/`oil.nvim`/`mini.nvim`, or a focused snacks picker list / the Snacks Explorer sidebar, press `<leader>as` on a file to add it to Claude's context
   - For modal snacks pickers (`Snacks.picker.files()`/`grep()`), which keep focus in the input box, bind a picker action that calls `require("claudecode").send_at_mention(...)` for the selected item(s) — the [claude-fzf.nvim](#-claude-fzfnvim) community extension does the equivalent for `fzf-lua`
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
- `:ClaudeCodeSendText {text}` - Send text to the open Claude terminal and submit it (`!` to insert without submitting; `native`/`snacks` providers only)
- `:ClaudeCodeAdd <file-path> [start-line] [end-line]` - Add specific file to Claude context with optional line range
- `:ClaudeCodeDiffAccept` - Accept diff changes
- `:ClaudeCodeDiffDeny` - Reject diff changes
- `:ClaudeCodeCloseAllDiffs` - Close pending Claude diffs (leaves accepted/saved diffs intact)

## Sending text to the Claude terminal

`:ClaudeCodeSendText {text}` types `{text}` into the open Claude terminal and submits it — useful for scripting and keymaps. Use `:ClaudeCodeSendText!` to insert the text without submitting. The same is available programmatically:

```lua
local terminal = require("claudecode.terminal")
terminal.send_to_terminal("run the test suite") -- types + submits
terminal.send_to_terminal("draft prompt", { submit = false }) -- insert only
```

This writes directly to the terminal's job channel, so it only works with the in-editor providers (`native`/`snacks`). The `external`/`none` providers run Claude outside Neovim, where there is no pane to write to (a warning is logged).

## Working with Diffs

When Claude proposes changes, the plugin opens a native Neovim diff view:

- **Accept**: `:w` (save) or `<leader>aa`
- **Reject**: `:q` or `<leader>ad`

You can edit Claude's suggestions before accepting them.

If a diff is resolved outside this Neovim (for example via Claude remote control on another device) the diff windows would otherwise stay open. They are now closed automatically when the Claude session that opened them disconnects. If you resolve diffs remotely while the session is still connected, run `:ClaudeCodeCloseAllDiffs` to clear the leftover pending proposals — it leaves any diff you have already accepted (`:w`) but whose file has not been written yet untouched, so your saved edits are never discarded.

## Events

The plugin fires `User` autocmds you can hook with `nvim_create_autocmd`.

### `ClaudeCodeSendComplete`

Fired once per file, synchronously, when a send (`:ClaudeCodeSend`, `:ClaudeCodeAdd`, tree add, etc.) is **accepted while a Claude client is connected**. This is the recommended way to focus a Claude session that runs **outside** Neovim (`provider = "none"`/`"external"`), where `focus_after_send` cannot help.

The autocmd `data` carries:

| field        | type           | notes                                                                                |
| ------------ | -------------- | ------------------------------------------------------------------------------------ |
| `file_path`  | `string`       | The formatted/cwd-relative path Claude received                                      |
| `start_line` | `integer\|nil` | **0-indexed** (Claude convention, not 1-indexed editor lines); `nil` for whole files |
| `end_line`   | `integer\|nil` | 0-indexed; `nil` for whole-file/directory sends                                      |
| `context`    | `string\|nil`  | Internal trigger tag (e.g. `"ClaudeCodeSend"`); best-effort, may change              |

Notes and caveats:

- Fires at **acceptance** time, not delivery — sending is debounced, so a later transport failure is logged, not reported here.
- Fires **per file**: sending a multi-file selection from a file-explorer buffer (`:ClaudeCodeSend` / `:ClaudeCodeTreeAdd`) fires it once per file. `:ClaudeCodeAdd` sends a single path and fires once. Keep handlers idempotent.
- Fires only when Claude is **already connected** at send time; a send that queues while Claude is launching is delivered later without firing this event.

Example — focus a tmux pane after sending (supply your own pane target):

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "ClaudeCodeSendComplete",
  callback = function(ev)
    -- ev.data.file_path / ev.data.start_line / ev.data.end_line / ev.data.context
    if vim.env.TMUX then
      vim.fn.system({ "tmux", "select-pane", "-t", "{last}" }) -- replace target as needed
    end
  end,
})
```

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
    -- When true, successful sends focus the in-editor Claude terminal if already
    -- connected. NOTE: this only works for in-editor providers (snacks/native);
    -- it has no effect with provider = "none"/"external" (Claude runs outside
    -- Neovim). For those, hook the `User ClaudeCodeSendComplete` event (see Events).
    focus_after_send = false,

    -- Selection Tracking
    track_selection = true,
    visual_demotion_delay_ms = 50,

    -- Terminal Configuration
    terminal = {
      split_side = "right", -- "left" or "right"
      split_width_percentage = 0.30,
      -- Optional: shrink (or widen) the terminal while a diff is open. Defaults to
      -- split_width_percentage when unset, preserving today's behavior.
      diff_split_width_percentage = nil, -- e.g. 0.20 to give diffs more room
      provider = "auto", -- "auto", "snacks", "native", "external", "none", or custom provider table
      auto_close = true,
      snacks_win_opts = {}, -- Opts to pass to `Snacks.terminal.open()` - see Floating Window section below
      -- Work around a Neovim core bug (< 0.12.2) that fragments large pastes into
      -- the terminal, making Cmd+V appear to truncate ([#161]). true | false | "auto"
      -- ("auto", the default, enables it only on affected Neovim versions).
      fix_streamed_paste = "auto",

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
      auto_resize_terminal = true, -- Let the plugin manage the terminal width across the diff lifecycle; set false to own it via the User autocmds below
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

### Diff Lifecycle Events

The plugin fires `User` autocmds when a diff opens and closes, so you can react to
the review lifecycle from your own config (resize windows, toggle a colorscheme,
update a statusline, etc.). They are emitted regardless of `auto_resize_terminal`.

| Event pattern          | When                                  | `event.data` fields                                                                                                      |
| ---------------------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `ClaudeCodeDiffOpened` | A proposed-edit diff has opened       | `tab_name`, `file_path`, `new_file_path`, `is_new_file`, `diff_window`, `target_window`, `terminal_window`, `tab_number` |
| `ClaudeCodeDiffClosed` | The diff was accepted/rejected/closed | `tab_name`, `file_path`, `reason`                                                                                        |

`reason` is a best-effort, human-readable label (e.g. `"diff accepted"`, `"diff rejected"`, `"replaced by new diff"`); treat it as diagnostic text, not a stable enum to branch on. `tab_number` is only set when the diff opened in its own tab, and `terminal_window` may be `nil` if no Claude terminal is visible.

To fully own the terminal width during diffs, set `diff_opts.auto_resize_terminal = false`
(so the plugin applies no width policy of its own) and resize from the events yourself.
Note this is "own the width via the events", not "freeze the width": the diff layout still
runs `wincmd =`, which equalizes splits, so set your desired width in the `ClaudeCodeDiffOpened`
handler — it fires after the layout is built, so it wins:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "ClaudeCodeDiffOpened",
  callback = function(ev)
    local term = ev.data.terminal_window
    if term and vim.api.nvim_win_is_valid(term) then
      vim.api.nvim_win_set_width(term, math.floor(vim.o.columns * 0.20))
    end
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = "ClaudeCodeDiffClosed",
  callback = function(ev)
    -- restore your preferred idle layout here
  end,
})
```

> For the common "just make the terminal narrower during diffs" case you don't need
> the events at all — set `terminal.diff_split_width_percentage` and leave
> `auto_resize_terminal = true`.

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
- `focus_after_send` has no effect here (there is no in-editor terminal to focus); enabling it logs a one-time warning at startup. To focus your external session after a send, hook the [`User ClaudeCodeSendComplete`](#claudecodesendcomplete) event.

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

See [DEVELOPMENT.md](./DEVELOPMENT.md) for build instructions and development guidelines. Tests can be run with `mise run test`.

## License

[MIT](LICENSE)

## Acknowledgements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) by Anthropic
- Inspired by analyzing the official VS Code extension
- Built with assistance from AI (how meta!)

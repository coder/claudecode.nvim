---Shared utility functions for claudecode.nvim
---@module 'claudecode.utils'

local M = {}

---Normalizes focus parameter to default to true for backward compatibility
---@param focus boolean? The focus parameter
---@return boolean valid Whether the focus parameter is valid
function M.normalize_focus(focus)
  if focus == nil then
    return true
  else
    return focus
  end
end

---Maps Ctrl-Z in terminal mode on a buffer to `:suspend`. Otherwise the terminal passes Ctrl-Z to Claude Code, which
---suspends itself and cannot be resumed from the Neovim terminal (#194). A buffer-local mapping that already exists
---stays, so a user's `FileType` handler can replace it.
---@param bufnr number The Claude terminal buffer
function M.map_terminal_suspend(bufnr)
  local existing = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg("<C-z>", "t", false, true)
  end)
  if existing.buffer == 1 then
    return
  end
  vim.keymap.set("t", "<C-z>", "<Cmd>suspend<CR>", { buffer = bufnr, desc = "Suspend Neovim" })
end

---Show `buf` in `win` without running BufEnter handlers. A handler of a terminal buffer can queue an insert with
---`startinsert` (Snacks' auto_insert, #423), and the insert then starts in the window the cursor ends in, not in `win`.
---'eventignore' is back to the caller's value afterwards, also when the call raises.
---@param win number
---@param buf number
function M.win_set_buf_without_bufenter(win, buf)
  local saved = vim.o.eventignore
  -- A `-BufEnter` entry wins wherever it stands in the list.
  local ignored = {}
  for entry in saved:gmatch("[^,]+") do
    if entry:lower() ~= "-bufenter" then
      table.insert(ignored, entry)
    end
  end
  table.insert(ignored, "BufEnter")
  vim.o.eventignore = table.concat(ignored, ",")
  local ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)
  vim.o.eventignore = saved
  if not ok then
    error(err, 0)
  end
end

local held_for_windows = {}

local function windows_allowed()
  return pcall(vim.api.nvim_set_current_win, vim.api.nvim_get_current_win())
end

local function retry_held_for_windows()
  if not windows_allowed() then
    vim.defer_fn(retry_held_for_windows, 50)
    return
  end
  local due = held_for_windows
  held_for_windows = {}
  for _, fn in ipairs(due) do
    -- One callback each, so a function that raises does not stop the others.
    vim.schedule(function()
      M.when_windows_allowed(fn)
    end)
  end
end

---Run `fn` now when Neovim lets the plugin change windows, else once it does: one timer checks every 50 ms for all
---held functions. Neovim refuses window changes in the command-line window (E11) and under textlock (E565), and
---timers and scheduled functions run in both, for example during a `vim.wait` under textlock. Neovim has no flag for
---textlock, so the gate asks: setting the current window to itself fails in both states and changes nothing
---otherwise. Not CmdwinLeave: it runs while the window is still open, and textlock has no event. Held functions run
---in no fixed order, so `fn` reads state when it runs.
---@param fn fun()
function M.when_windows_allowed(fn)
  assert(type(fn) == "function", "when_windows_allowed expects a function")
  if windows_allowed() then
    fn()
    return
  end
  table.insert(held_for_windows, fn)
  if #held_for_windows == 1 then
    vim.defer_fn(retry_held_for_windows, 50)
  end
end

---Split a command string into an argument vector using POSIX shell word rules.
---
---Honors single quotes, double quotes, and backslash escapes so terminal
---providers can spawn Claude directly (without a shell) while preserving quoted
---arguments such as `--message='hello world'`. Spawning without a shell also
---avoids glob expansion of bracketed model aliases like `opus[1m]` (e.g. zsh
---aborts an unmatched glob with "no matches found", so Claude never launches).
---@param cmd string The command string to split.
---@return string[] argv The parsed argument vector.
function M.shell_split(cmd)
  local argv = {}
  local current = nil -- nil = between words; string (incl. "") = building a word
  local i = 1
  local n = #cmd
  while i <= n do
    local c = cmd:sub(i, i)
    if c == " " or c == "\t" then
      if current ~= nil then
        argv[#argv + 1] = current
        current = nil
      end
    elseif c == "'" then
      -- Single quotes: everything up to the next single quote is literal.
      current = current or ""
      local close = cmd:find("'", i + 1, true)
      if close then
        current = current .. cmd:sub(i + 1, close - 1)
        i = close
      else
        current = current .. cmd:sub(i + 1)
        i = n
      end
    elseif c == '"' then
      -- Double quotes: backslash escapes only " \ $ `.
      current = current or ""
      i = i + 1
      while i <= n do
        local d = cmd:sub(i, i)
        if d == '"' then
          break
        elseif d == "\\" and i < n then
          local nextc = cmd:sub(i + 1, i + 1)
          if nextc == '"' or nextc == "\\" or nextc == "$" or nextc == "`" then
            current = current .. nextc
            i = i + 1
          else
            current = current .. d
          end
        else
          current = current .. d
        end
        i = i + 1
      end
    elseif c == "\\" and i < n then
      current = (current or "") .. cmd:sub(i + 1, i + 1)
      i = i + 1
    else
      current = (current or "") .. c
    end
    i = i + 1
  end
  if current ~= nil then
    argv[#argv + 1] = current
  end
  return argv
end

---Expand a leading `~` or `~/` in a single argument to the user's home
---directory, matching shell tilde expansion at the start of a word. Embedded
---tildes (e.g. `--path=~/x`) and the `~user` form are intentionally left
---untouched, exactly as a shell would treat a non-word-initial tilde.
---@param arg string
---@return string
function M.expand_tilde(arg)
  if arg:sub(1, 1) ~= "~" then
    return arg
  end
  local home = os.getenv("HOME")
  if not home or home == "" then
    return arg
  end
  if arg == "~" then
    return home
  elseif arg:sub(1, 2) == "~/" then
    return home .. arg:sub(2)
  end
  return arg
end

---Parse a command string into an argv list the way a shell would for our
---purposes: split into words honoring quotes/escapes (see `shell_split`), then
---expand a leading tilde in each word. Terminal providers use this to spawn
---Claude directly (no shell) while still preserving quoted arguments and the
---documented `terminal_cmd = "~/.claude/local/claude"` local-install path.
---Globbing and variable expansion are deliberately NOT performed -- avoiding the
---shell is what keeps bracketed aliases like `opus[1m]` intact.
---@param cmd string
---@return string[] argv
function M.parse_command(cmd)
  local argv = M.shell_split(cmd)
  for i = 1, #argv do
    argv[i] = M.expand_tilde(argv[i])
  end
  return argv
end

-- The selection type (v, V or CTRL-V) of each mode that has a selection. Select mode (s, S, CTRL-S) has the same
-- selection as Visual mode, and so does Visual mode for one command after CTRL-O in Select mode (vs, Vs, CTRL-Vs).
local SELECTION_TYPE = {
  v = "v",
  V = "V",
  ["\22"] = "\22",
  s = "v",
  S = "V",
  ["\19"] = "\22",
  vs = "v",
  Vs = "V",
  ["\22s"] = "\22",
}

---Returns the selection type (v, V or CTRL-V) of a mode from nvim_get_mode(), or nil when it has no selection.
---@param mode string|nil
---@return string|nil
function M.selection_type(mode)
  return SELECTION_TYPE[mode]
end

---Returns the length of the well-formed UTF-8 sequence at byte i of text. For an ill-formed sequence, returns
---nil and the length of its longest valid prefix (at least 1), which a decoder replaces with one U+FFFD.
---@param text string
---@param i integer
---@return integer|nil length, integer? invalid_length
function M.utf8_sequence_length(text, i)
  local lead = text:byte(i)
  local length, low, high
  if lead < 0x80 then
    return 1
  elseif lead >= 0xC2 and lead <= 0xDF then
    length, low, high = 2, 0x80, 0xBF
  elseif lead == 0xE0 then
    length, low, high = 3, 0xA0, 0xBF -- no overlong forms
  elseif lead == 0xED then
    length, low, high = 3, 0x80, 0x9F -- no surrogates
  elseif lead >= 0xE1 and lead <= 0xEF then
    length, low, high = 3, 0x80, 0xBF
  elseif lead == 0xF0 then
    length, low, high = 4, 0x90, 0xBF -- no overlong forms
  elseif lead >= 0xF1 and lead <= 0xF3 then
    length, low, high = 4, 0x80, 0xBF
  elseif lead == 0xF4 then
    length, low, high = 4, 0x80, 0x8F -- nothing above U+10FFFF
  else
    return nil, 1
  end
  for offset = 1, length - 1 do
    local byte = text:byte(i + offset)
    if not byte or byte < low or byte > high then
      return nil, offset
    end
    low, high = 0x80, 0xBF
  end
  return length
end

---Returns text with each ill-formed UTF-8 sequence replaced by U+FFFD. A buffer line or name can hold any bytes,
---and the client drops the connection when a message is not valid UTF-8.
---@param text string
---@return string
function M.valid_utf8(text)
  local parts = {}
  local valid_from, i = 1, 1
  while i <= #text do
    local length, invalid_length = M.utf8_sequence_length(text, i)
    if length then
      i = i + length
    else
      table.insert(parts, text:sub(valid_from, i - 1))
      table.insert(parts, "\239\191\189")
      i = i + invalid_length
      valid_from = i
    end
  end
  table.insert(parts, text:sub(valid_from))
  return table.concat(parts)
end

-- Neovim 0.8 and 0.9 bundle a LuaJIT older than its commit e86990f7f of 2023-09-21, which fixes LuaJIT issue 1066:
-- after a C function runs Lua on another thread and then raises into a pcall, `cur_L` still names that thread, and
-- the next exit from a compiled trace crashes (the issue shows a crash in `lj_trace_exit`). The commit sets `cur_L`
-- again in `err_unwind` (src/lj_err.c). A Neovim API call in a coroutine that runs a Lua callback and then raises
-- behaves like that C function, and Neovim aborts (exit 134 or 139). We did not read the LuaJIT source for other code
-- that uses `cur_L`. Measured: with the JIT off and its traces flushed while the coroutine runs, Neovim survives
-- (tests/integration/diff_tool_coroutine_jit_spec.lua). Rolling releases are numbered 2.1.<unix time of the commit>.
-- A version that is no string, or does not read that way, counts as affected, which costs only a flush.
local jit_affected = jit ~= nil and (tonumber(tostring(jit.version):match("^LuaJIT 2%.1%.(%d+)$")) or 0) < 1695261248

---Turns the JIT back on when `was_on`, and passes the other arguments on as they are, trailing nils included.
local function restore_jit(was_on, ...)
  if was_on then
    jit.on()
  end
  return ...
end

---`coroutine.resume` for the coroutine of a tool (`handle_invoke` and the resolution of a blocking diff). On a LuaJIT
---with issue 1066 it turns the JIT off and flushes its traces before the resume, and gives the JIT back as it was.
---@param co thread
---@param ... any Values for the coroutine
---@return boolean success
---@return any ... What `coroutine.resume` returns
function M.resume_tool_coroutine(co, ...)
  local was_on = jit_affected and jit.status()
  if jit_affected then
    jit.off()
    jit.flush()
  end
  return restore_jit(was_on, coroutine.resume(co, ...))
end

return M

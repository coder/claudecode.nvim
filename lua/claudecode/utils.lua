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

return M

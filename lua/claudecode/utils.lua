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

return M

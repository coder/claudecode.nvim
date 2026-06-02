--- Compatibility shim for a Neovim core bug that fragments large bracketed
--- pastes into a `:terminal` buffer.
---
--- See https://github.com/coder/claudecode.nvim/issues/161 and the upstream fix
--- https://github.com/neovim/neovim/pull/39152 (landed in Neovim 0.12.2).
---
--- On affected Neovim (< 0.12.2), the default `vim.paste` runs `nvim_put()` once
--- per streamed phase (1 -> 2 -> 3). In a terminal buffer each write is
--- independently wrapped in bracketed-paste markers (ESC[200~ .. ESC[201~) when
--- the inner program enabled them, so a single large paste reaches the program
--- running in the terminal (e.g. the Claude CLI) as N separate paste events.
--- Claude renders N `[Pasted text #k]` placeholders with phase-boundary bytes
--- leaking between them, which the user perceives as truncation.
---
--- This module installs a cooperative `vim.paste` override that coalesces the
--- streamed phases of a paste into ONE non-streamed (`phase == -1`) replay, but
--- only for the plugin's own managed terminal buffer. Everything else delegates
--- to the original handler unchanged. The override is a no-op on Neovim >= 0.12.2
--- (which already coalesces) unless explicitly forced.
--- @module 'claudecode.terminal.paste_fix'

local M = {}

-- Accumulator for the in-flight streamed paste. Pastes are processed
-- sequentially, so a single shared buffer is safe.
local chunks = {}
local installed = false

--- True if the running Neovim has the per-phase terminal-paste fragmentation
--- bug, i.e. is older than the 0.12.2 fix.
--- @return boolean
function M.is_affected_version()
  local v = vim.version and vim.version()
  if type(v) ~= "table" or type(v.major) ~= "number" then
    return false
  end
  if v.major ~= 0 then
    return false -- 1.0+ is well past the fix
  end
  return v.minor < 12 or (v.minor == 12 and (v.patch or 0) < 2)
end

--- Resolve whether the shim should be active for a given config value.
--- @param opt boolean|string|nil `true` (force on), `false` (off), or `"auto"`/nil
---        (on only for affected Neovim versions; the default).
--- @return boolean
function M.should_enable(opt)
  if opt == false then
    return false
  end
  if opt == true then
    return true
  end
  -- "auto" / nil
  return M.is_affected_version()
end

--- Append one streamed phase's `lines` to `acc`, re-gluing the mid-line seam.
---
--- `lines` is a `readfile()`-style split of the chunk on "\n" with the delimiters
--- dropped, so when a paste is fragmented across chunks the boundary usually
--- falls mid-line: the last element of the previous chunk and the first element
--- of this chunk are two halves of the same source line. Appending naively would
--- insert a spurious newline at every seam, so the first incoming line is joined
--- onto the last buffered line instead.
--- @param acc string[] accumulator (mutated in place)
--- @param lines string[] the current phase's lines
function M._accumulate(acc, lines)
  if #lines == 0 then
    return
  end
  if #acc == 0 then
    for _, line in ipairs(lines) do
      acc[#acc + 1] = line
    end
  else
    acc[#acc] = acc[#acc] .. lines[1]
    for i = 2, #lines do
      acc[#acc + 1] = lines[i]
    end
  end
end

--- Whether `bufnr` is the plugin's managed Claude terminal buffer.
--- @param bufnr integer
--- @return boolean
local function is_managed_terminal(bufnr)
  if vim.bo[bufnr].buftype ~= "terminal" then
    return false
  end
  -- Lazy require to avoid a load-time dependency cycle (terminal -> paste_fix).
  local ok, terminal = pcall(require, "claudecode.terminal")
  if not ok then
    return false
  end
  local active = terminal.get_active_terminal_bufnr()
  return active ~= nil and active == bufnr
end

--- Install the cooperative `vim.paste` override (idempotent). Captures the
--- current `vim.paste` and delegates to it for everything except streamed pastes
--- into the plugin's managed terminal buffer.
function M.install()
  if installed then
    return
  end
  installed = true
  chunks = {}

  local orig_paste = vim.paste
  vim.paste = function(lines, phase)
    -- Only intervene for streamed pastes (phase 1/2/3) into the plugin's own
    -- terminal buffer. `phase == -1` is already a whole, non-streamed paste.
    if phase == -1 or not is_managed_terminal(vim.api.nvim_get_current_buf()) then
      return orig_paste(lines, phase)
    end

    if phase == 1 then
      chunks = {}
    end
    M._accumulate(chunks, lines)

    if phase == 3 then
      local buffered = chunks
      chunks = {}
      -- Replay as a single non-streamed paste so the terminal wraps it in one
      -- bracketed-paste segment.
      return orig_paste(buffered, -1)
    end
    return true
  end
end

--- Apply the shim according to the resolved config value.
--- @param opt boolean|string|nil
function M.apply(opt)
  if M.should_enable(opt) then
    M.install()
  end
end

--- Test helper: report whether the override has been installed.
--- @return boolean
function M._is_installed()
  return installed
end

return M

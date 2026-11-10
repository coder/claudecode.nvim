--- Compatibility shim for a Neovim core bug (< 0.12.2) that fragments a large
--- bracketed paste into a `:terminal` across `vim.paste` phases, so the program
--- in the terminal sees it as N separate pastes. Coalesces the streamed phases
--- into one `phase == -1` replay, scoped to the plugin's managed terminal; a
--- no-op on Neovim >= 0.12.2 unless forced. See coder/claudecode.nvim#161 and the
--- upstream fix neovim/neovim#39152.
--- @module 'claudecode.terminal.paste_fix'

local M = {}

local chunks = {} -- accumulator for the in-flight streamed paste (pastes are sequential)
local installed = false -- the global vim.paste wrap happens at most once
local enabled = false -- config-controlled; lets a later setup() disable in place
local streaming = false -- does the current stream target the managed terminal? (decided at phase 1)
local target_win = nil -- window that owns the paste, captured at phase 1, for the phase-3 replay
local terminal_mod = nil -- lazily required to avoid a terminal -> paste_fix cycle

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
  local minor = v.minor or 0
  local patch = v.patch or 0
  if minor < 12 or (minor == 12 and patch < 2) then
    return true
  end
  -- The fix shipped in the 0.12.2 *release*. A 0.12.2 prerelease/nightly
  -- (vim.version().prerelease is set, e.g. "dev") can predate the backport, so
  -- treat it as affected. Enabling the shim on a build that already has the fix
  -- is a verified no-op, so erring toward "affected" at the boundary is safe.
  if minor == 12 and patch == 2 and v.prerelease then
    return true
  end
  return false
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

--- Append one streamed phase's `lines` to `acc`. `lines` is a `readfile()`-style
--- split, so consecutive chunks meet mid-line; re-glue the seam rather than
--- inserting a spurious newline at every chunk boundary.
--- @param acc string[] accumulator (mutated in place)
--- @param lines string[]
function M._accumulate(acc, lines)
  if #lines == 0 then
    return
  end
  local start = 1
  if #acc > 0 then
    acc[#acc] = acc[#acc] .. lines[1] -- re-glue mid-line seam
    start = 2
  end
  for i = start, #lines do
    acc[#acc + 1] = lines[i]
  end
end

--- Whether `bufnr` is the plugin's managed terminal. Must never throw: it runs on
--- the paste hot path, so failures degrade to "not managed".
--- @param bufnr integer
--- @return boolean
local function is_managed_terminal(bufnr)
  if vim.bo[bufnr].buftype ~= "terminal" then
    return false
  end
  if not terminal_mod then
    local ok, mod = pcall(require, "claudecode.terminal")
    if not ok then
      return false
    end
    terminal_mod = mod
  end
  local ok, active = pcall(terminal_mod.get_active_terminal_bufnr)
  return ok and active ~= nil and active == bufnr
end

--- Install the cooperative `vim.paste` override (idempotent). Delegates to the
--- captured original except for a streamed paste into the managed terminal, and
--- honours `enabled` at call time so it can be disabled without uninstalling.
function M.install()
  if installed then
    return
  end
  installed = true

  local orig_paste = vim.paste
  vim.paste = function(lines, phase)
    if not enabled then
      return orig_paste(lines, phase)
    end

    -- Decide once per stream (at phase 1) whether it targets the managed
    -- terminal, capturing the window so phases 2/3 follow that decision and the
    -- replay can be aimed back at it.
    if phase == 1 then
      streaming = is_managed_terminal(vim.api.nvim_get_current_buf())
      target_win = vim.api.nvim_get_current_win()
      chunks = {}
    end

    if not streaming or phase == -1 then
      return orig_paste(lines, phase)
    end

    M._accumulate(chunks, lines)

    if phase == 3 then
      local buffered = chunks
      chunks = {}
      streaming = false
      -- Replay as a single non-streamed paste through the original handler so
      -- Neovim's own terminal paste delivers it (and decides whether to emit
      -- bracketed-paste markers based on the child's state — which is not
      -- queryable from Lua). If focus has moved off the terminal since phase 1
      -- (e.g. a scheduled callback or a GUI/RPC paste stream), run the replay in
      -- the captured window via nvim_win_call so it still reaches the terminal
      -- instead of the now-current buffer.
      if target_win and target_win ~= vim.api.nvim_get_current_win() and vim.api.nvim_win_is_valid(target_win) then
        return vim.api.nvim_win_call(target_win, function()
          return orig_paste(buffered, -1)
        end)
      end
      return orig_paste(buffered, -1)
    end
    return true
  end
end

--- Apply the shim per the resolved config value: set the active state (so a later
--- call with `false` disables an installed override) and install on first enable.
--- @param opt boolean|string|nil
function M.apply(opt)
  enabled = M.should_enable(opt)
  if enabled then
    M.install()
  end
end

--- Test helper: report whether the override has been installed.
--- @return boolean
function M._is_installed()
  return installed
end

--- Test helper: report whether the override is currently active.
--- @return boolean
function M._is_enabled()
  return enabled
end

return M

-- Repro fixture for issue #161:
--   "Pasting text with Cmd+V truncates content in the Claude Code terminal"
--
-- Root cause (confirmed): on Neovim <= 0.11.x, a single large bracketed paste
-- into a :terminal buffer is streamed through vim.paste() in phases (1->2->3),
-- and the default handler wraps EACH streamed write to the inner PTY in its own
-- ESC[200~ ... ESC[201~ pair. Claude Code then classifies every segment as a
-- separate paste event ("[Pasted text #N]"), which presents as truncation.
-- Neovim 0.12+ coalesces the stream into a single bracketed-paste segment, so
-- the bug does not reproduce there.
--
-- This fixture replaces the `claude` binary with a tiny bracketed-paste
-- "observer" (observer.py) that logs how many ESC[200~/ESC[201~ segments the
-- inner PTY receives. That count is the signal:
--   * >1 segment  => bug reproduced (fragmentation)
--   *  1 segment  => correct (single logical paste)
--
-- Usage (from repo root):
--   source fixtures/nvim-aliases.sh
--   vv paste-repro          # open Neovim with this fixture
--   <leader>ac              # open the Claude terminal (runs the observer)
--   then paste 100+ lines with Cmd+V and inspect the observer log
--
-- The observer log path is printed on startup (and via <leader>al). Toggle the
-- proposed workaround with the APPLY_PASTE_FIX=1 environment variable.

local config_dir = vim.fn.stdpath("config") -- fixtures/paste-repro
local repo_root = vim.fn.fnamemodify(config_dir, ":h:h") -- repo root
vim.opt.rtp:prepend(repo_root)

-- Low-noise editor settings.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
vim.o.swapfile = false

local observer = config_dir .. "/observer.py"
local log = os.getenv("PASTE_OBSERVER_LOG") or (vim.fn.stdpath("cache") .. "/claudecode-paste-observer.log")

-- Optional: apply the workaround proposed in issue #161 (huiyu + kyleawayan).
-- Coalesces the streamed phases into a single phase == -1 paste so the inner
-- PTY receives exactly one bracketed-paste segment.
local fix_active = os.getenv("APPLY_PASTE_FIX") == "1"
if fix_active then
  local chunks = {}
  local orig_paste = vim.paste
  vim.paste = function(lines, phase)
    if vim.bo.buftype ~= "terminal" or phase == -1 then
      return orig_paste(lines, phase)
    end
    if phase == 1 then
      chunks = {}
    end
    if #lines > 0 then
      if #chunks == 0 then
        for _, line in ipairs(lines) do
          chunks[#chunks + 1] = line
        end
      else
        -- The stream is split mid-line at chunk boundaries: the first incoming
        -- line continues the last buffered line, so join them.
        chunks[#chunks] = chunks[#chunks] .. lines[1]
        for i = 2, #lines do
          chunks[#chunks + 1] = lines[i]
        end
      end
    end
    if phase == 3 then
      local buffered = chunks
      chunks = {}
      return orig_paste(buffered, -1)
    end
    return true
  end
end

local ok, claudecode = pcall(require, "claudecode")
assert(ok, "Failed to load claudecode.nvim from repo root: " .. tostring(claudecode))

claudecode.setup({
  auto_start = false,
  log_level = "info",
  -- Replace the `claude` CLI with the bracketed-paste observer. The observer
  -- takes its log path as argv[1]. The native provider splits terminal_cmd on
  -- spaces into an argv list, so neither path may contain spaces.
  terminal_cmd = "python3 " .. observer .. " " .. log,
  terminal = {
    provider = "native",
    auto_close = false,
  },
})

local function ensure_started()
  local ok_start, started_or_err, err = pcall(function()
    return claudecode.start(false)
  end)
  if not ok_start then
    vim.notify("ClaudeCode start crashed: " .. tostring(started_or_err), vim.log.levels.ERROR)
    return false
  end
  if started_or_err or err == "Already running" then
    return true
  end
  vim.notify("ClaudeCode failed to start: " .. tostring(err), vim.log.levels.ERROR)
  return false
end

vim.keymap.set("n", "<leader>ac", function()
  if ensure_started() then
    require("claudecode.terminal").simple_toggle({}, nil)
  end
end, { desc = "Toggle Claude (observer) terminal" })

vim.keymap.set("n", "<leader>al", function()
  vim.notify("[paste-repro] observer log: " .. log)
end, { desc = "Show observer log path" })

-- Keep this message SHORT and on a single screen line: a banner long enough to
-- wrap trips Neovim's "Press ENTER to continue" hit-enter prompt, which would
-- swallow the <leader>ac keystroke when driving this fixture from a script.
vim.schedule(function()
  vim.notify("[paste-repro] ready" .. (fix_active and " (fix on)" or "") .. " — <leader>ac")
end)

-- For deterministic, non-interactive driving (e.g. agent-tty): when
-- PASTE_REPRO_AUTOOPEN=1, open the observer terminal automatically on startup
-- so the harness never has to time a <leader>ac keystroke.
if os.getenv("PASTE_REPRO_AUTOOPEN") == "1" then
  vim.schedule(function()
    if ensure_started() then
      require("claudecode.terminal").simple_toggle({}, nil)
    end
  end)
end

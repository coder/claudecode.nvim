-- AtMostOneClaude: provider = "auto" picks snacks after a reload when snacks.nvim became loadable mid-session. The
-- Claude that the native provider started then ran beside the one snacks started. Without a reload, nothing switches.
-- Path: setup with provider "auto" while snacks.nvim is not on the runtimepath; you open Claude (native); snacks.nvim
-- becomes loadable (:packadd); you open Claude; the plugin reloads; you open Claude.
-- Fixed in #464: the replay shows the promise kept. A BUG line means the finding is back.
local lib = dofile(os.getenv("REPLAY_LIB"))
local function setup()
  local term = require("claudecode.terminal")
  term.setup({ provider = "auto", show_native_term_exit_tip = false }, "sh -c 'sleep 60'")
  return term
end
local term = setup()
lib.step("snacks loadable at setup: " .. tostring(pcall(require, "snacks")))
term.open()
lib.settle()
vim.cmd("stopinsert")
lib.step(string.format("open: %d Claude running (native)", #lib.running()))
vim.opt.rtp:append(os.getenv("SNACKS_NVIM"))
lib.step("snacks.nvim added to the runtimepath; loadable now: " .. tostring(pcall(require, "snacks")))
term.open()
lib.settle()
lib.step(string.format("open: %d Claude running (no switch without a reload)", #lib.running()), #lib.running() > 1)
term = lib.reload(setup)
lib.step("the plugin's modules reload and setup runs again")
term.open()
lib.settle()
lib.step(string.format("open after the reload: %d Claude running", #lib.running()), #lib.running() > 1)
lib.finish()

-- CloseStopsClaude: after a reload of the plugin's modules, :ClaudeCodeClose leaves Claude running.
-- Path: you open Claude (native); the plugin reloads (:Lazy reload); you run :ClaudeCodeClose (terminal.close).
-- Fixed in #464: the replay shows the promise kept. A BUG line means the finding is back.
local lib = dofile(os.getenv("REPLAY_LIB"))
local function setup()
  local term = require("claudecode.terminal")
  term.setup({ provider = "native", show_native_term_exit_tip = false }, "sh -c 'sleep 60'")
  return term
end
local term = setup()

term.open()
lib.settle()
vim.cmd("stopinsert")
lib.step(
  string.format(
    "open: %d Claude running, shown: %s",
    #lib.running(),
    tostring(lib.windows_showing(lib.running()[1]) > 0)
  )
)
term = lib.reload(setup)
lib.step("the plugin's modules reload and setup runs again")
term.close()
lib.wait(300)
lib.step(string.format(":ClaudeCodeClose: %d Claude running", #lib.running()), #lib.running() ~= 0)
lib.finish()

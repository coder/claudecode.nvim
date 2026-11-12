-- AtMostOneClaude: a native Claude that is hidden when the plugin reloads is not adopted, so the next open starts a
-- second Claude.
-- Path: you open Claude (native); you hide it (:ClaudeCode); the plugin reloads (:Lazy reload); you open Claude.
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
term.simple_toggle()
lib.step(
  string.format(
    "open, then hide: %d Claude running, shown in %d windows",
    #lib.running(),
    lib.windows_showing(lib.running()[1])
  )
)
term = lib.reload(setup)
lib.step("the plugin's modules reload and setup runs again")
term.open()
lib.settle()
lib.step(string.format("open: %d Claude running", #lib.running()), #lib.running() > 1)
lib.finish()

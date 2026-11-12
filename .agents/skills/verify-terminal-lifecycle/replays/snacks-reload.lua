-- AtMostOneClaude: with the snacks provider, the next open after a reload of the plugin's modules starts a second
-- Claude, and :ClaudeCodeClose cannot stop the first one.
-- Path: you open Claude (snacks); the plugin reloads (:Lazy reload); you open Claude.
-- Fixed in #464: the replay shows the promise kept. A BUG line means the finding is back.
local lib = dofile(os.getenv("REPLAY_LIB"))
local function setup()
  local term = require("claudecode.terminal")
  term.setup({ provider = "snacks", auto_close = true }, "sh -c 'sleep 60'")
  return term
end
local term = setup()
lib.step("provider in use is snacks: " .. tostring(require("claudecode.terminal.snacks").is_available()))

term.open()
lib.settle()
vim.cmd("stopinsert")
lib.step(string.format("open: %d Claude running", #lib.running()))
term = lib.reload(setup)
lib.step("the plugin's modules reload and setup runs again")
term.open()
lib.settle()
lib.step(string.format("open: %d Claude running", #lib.running()), #lib.running() > 1)
term.close()
lib.wait(300)
lib.step(string.format(":ClaudeCodeClose: %d Claude running", #lib.running()), #lib.running() > 0)
lib.finish()

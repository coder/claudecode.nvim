if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the terminal's placement with 'verbose' above 0", function()
    pending("needs a real Neovim")
  end)
  return
end

-- `expand("<abuf>")` raises E496 outside an autocmd when 'verbose' is above 0 (`:verbose`, `nvim -V1`), and the helper
-- asks it whether it runs inside an autocmd (`utils.win_set_buf_in_split`). A user who runs with 'verbose' set must
-- still get the terminal, so the cases go through the public commands, and they pass on a tree with no helper. Each
-- case runs in its own headless Neovim.
local child = require("tests.helpers.placement_child")

describe("the terminal's placement with 'verbose' above 0", function()
  local SCENARIO = [==[
-- P.path "new": the first :ClaudeCodeOpen. "hidden": a terminal that was started and hidden, then :ClaudeCodeOpen.
-- "diff": the terminal is shown, then openDiff in a new tab. P.verbose is the level to set, or 0 with P.modifier, which
-- runs the command as `:verbose ClaudeCodeOpen`.
local terminal = setup_native()
if P.path == "diff" then
  local config = vim.deepcopy(require("claudecode.config").defaults)
  config.diff_opts.open_in_new_tab = true
  require("claudecode.diff").setup(config)
end
if P.path ~= "new" then
  terminal.open()
  vim.cmd("stopinsert")
  if P.path == "hidden" then
    hide_terminal(terminal)
  end
end
local verbose = P.verbose or 0
vim.o.verbose = verbose
local ok, err
if P.path == "diff" then
  local tools = require("claudecode.tools.init")
  tools.register_all()
  _G.claude_deferred_responses = {}
  ok, err = pcall(function()
    local call = tools.handle_invoke({ id = "c" }, {
      name = "openDiff",
      arguments = {
        old_file_path = dir .. "/a.txt",
        new_file_path = dir .. "/a.txt",
        new_file_contents = "alpha changed\n",
        tab_name = "verbose",
      },
    })
    assert(not call.error, vim.inspect(call.error))
  end)
else
  ok, err = pcall(vim.cmd, (P.modifier and "verbose " or "") .. "ClaudeCodeOpen")
end
vim.o.verbose = 0
local term = terminal.get_active_terminal_bufnr()
local job = term and vim.b[term].terminal_job_id
result.ok = ok
result.err = ok and "" or tostring(err):match("E%d+:[^\n]*") or tostring(err):sub(-160)
result.terminal_windows = term and #vim.fn.win_findbuf(term) or -1
result.job_running = job ~= nil and vim.fn.jobwait({ job }, 0)[1] == -1
result.tabs = vim.fn.tabpagenr("$")
finish()
]==]

  local function expect_placed(result, expected_windows, expected_tabs)
    assert.is_true(result.ok, "the command must not fail: " .. vim.inspect(result))
    assert.equal("", result.err)
    assert.equal(expected_windows, result.terminal_windows, vim.inspect(result))
    assert.equal(expected_tabs, result.tabs, vim.inspect(result))
    assert.is_true(result.job_running, vim.inspect(result))
  end

  for _, level in ipairs({ 1, 15 }) do
    it("starts the terminal when 'verbose' is " .. level, function()
      expect_placed(child.run_to_end(SCENARIO, { path = "new", verbose = level }), 1, 1)
    end)
  end

  it("starts the terminal when the command runs as :verbose ClaudeCodeOpen", function()
    expect_placed(child.run_to_end(SCENARIO, { path = "new", modifier = true }), 1, 1)
  end)

  it("shows a hidden terminal when 'verbose' is 1", function()
    expect_placed(child.run_to_end(SCENARIO, { path = "hidden", verbose = 1 }), 1, 1)
  end)

  it("shows a hidden terminal when the command runs as :verbose ClaudeCodeOpen", function()
    expect_placed(child.run_to_end(SCENARIO, { path = "hidden", modifier = true }), 1, 1)
  end)

  it("opens a diff in a new tab, with the terminal shown there, when 'verbose' is 1", function()
    expect_placed(child.run_to_end(SCENARIO, { path = "diff", verbose = 1 }), 2, 2)
  end)
end)

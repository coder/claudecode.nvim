-- Real-Neovim check of the held selection (issue #246) through the real start path, with real autocmds and timers:
-- select text, press Esc, go to the Claude terminal, come back. Claude must still hold the selection. The unit tests
-- in tests/selection_test.lua mock the events, so they cannot see what Neovim fires for a terminal that is being
-- created: its BufEnter comes before the buffer has a name and before the provider registers it. Busted's mock vim
-- has no autocmds, so there these are pending; scripts/run_integration_tests_individually.sh runs them in Neovim.
-- CursorMoved and TextChanged fire from Neovim's main loop, which vim.wait() does not run, so these specs cannot
-- test them: tests/selection_test.lua covers them with the events mocked.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("a held selection with the real plugin", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("a held selection with the real plugin", function()
  local claudecode = require("claudecode")
  local selection = require("claudecode.selection")
  local server = require("claudecode.server.init")
  local real_broadcast, real_config_dir, config_dir

  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
  end

  -- Lets the real timers run: the debounce is 100 ms.
  local function wait(ms)
    vim.wait(ms, function()
      return false
    end, 10)
  end

  local function start(terminal_config, delay_ms)
    claudecode.setup({
      auto_start = false,
      log_level = "error",
      visual_demotion_delay_ms = delay_ms,
      terminal_cmd = "sh -c 'sleep 60'",
      terminal = terminal_config,
    })
    assert.is_true(claudecode.start(false))
    server.broadcast = function()
      return true
    end
  end

  local function open_file(line)
    local path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ line }, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end

  -- Select alpha (the first word) and release it with Esc: Claude holds it.
  local function select_and_release()
    press("ve")
    wait(150)
    press("<Esc>")
    wait(300)
    assert.are.equal("alpha", selection.get_latest_selection().text)
  end

  before_each(function()
    vim.o.hidden = true
    real_broadcast = server.broadcast
    real_config_dir = vim.env.CLAUDE_CONFIG_DIR
    config_dir = vim.fn.tempname()
    vim.fn.mkdir(config_dir, "p")
    vim.env.CLAUDE_CONFIG_DIR = config_dir
  end)

  after_each(function()
    pcall(claudecode.stop)
    server.broadcast = real_broadcast
    vim.env.CLAUDE_CONFIG_DIR = real_config_dir
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].buftype == "terminal" then
        pcall(vim.fn.jobstop, vim.bo[buf].channel)
      end
    end
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
  end)

  for _, delay_ms in ipairs({ 50, 1000 }) do
    it("keeps the selection when the Claude terminal first opens (delay " .. delay_ms .. ")", function()
      start({ provider = "native", show_native_term_exit_tip = false }, delay_ms)
      open_file("alpha beta gamma")
      select_and_release()

      require("claudecode.terminal").open()
      vim.cmd("stopinsert")
      wait(300)
      vim.cmd("wincmd p")
      wait(600 + delay_ms) -- the debounce, then the demotion

      assert.are.equal("alpha", selection.get_latest_selection().text)
    end)
  end

  it("keeps the selection through a terminal that only its name says is Claude's, in the same window", function()
    start({ provider = "none" }, 50)
    open_file("alpha beta gamma")
    local file_buf = vim.api.nvim_get_current_buf()
    vim.cmd("terminal sh -c 'sleep 60' claude")
    local term_buf = vim.api.nvim_get_current_buf()
    vim.cmd("stopinsert")
    vim.cmd("buffer " .. file_buf)
    wait(200)
    select_and_release()

    vim.cmd("buffer " .. term_buf)
    vim.cmd("stopinsert")
    wait(300)
    vim.cmd("buffer #")
    wait(600)

    assert.are.equal(file_buf, vim.api.nvim_get_current_buf())
    assert.are.equal("alpha", selection.get_latest_selection().text)
  end)
end)

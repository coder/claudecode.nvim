-- Real-Neovim check of a demotion that fires while you are in the Claude terminal (issue #246): select text, press
-- Esc, enter a new Claude terminal before the demotion fires, come back. Claude must still hold the selection. A new
-- terminal is not registered when its BufEnter fires, so nothing cancels the demotion there: with the default
-- visual_demotion_delay_ms of 50 it fires while the terminal is the current buffer, 100 ms before the debounce of the
-- terminal's own BufEnter would cancel it.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("a demotion that fires in the Claude terminal, with the real plugin", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("a demotion that fires in the Claude terminal, with the real plugin", function()
  local claudecode = require("claudecode")
  local selection = require("claudecode.selection")
  local server = require("claudecode.server.init")
  local terminal = require("claudecode.terminal")
  local real_broadcast, real_config_dir, config_dir, real_demotion

  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
  end

  -- Waits until the plugin has finished what it started: no debounce timer and no demotion timer is pending, and every
  -- vim.schedule callback that was queued before the call has run. A fixed wait ends in the loop iteration that fires
  -- the timers, before their callbacks run, when the main loop stalls under load.
  local function settle(keep_demotion)
    local drained = false
    vim.schedule(function()
      drained = true
    end)
    local done = vim.wait(10000, function()
      return drained
        and selection.state.debounce_timer == nil
        and (keep_demotion or selection.state.demotion_timer == nil)
    end, 10)
    assert.is_true(done, "the plugin still has a timer pending")
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
    if real_demotion then
      selection.handle_selection_demotion = real_demotion
      real_demotion = nil
    end
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

  local function start(delay_ms, terminal_config)
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

  -- Selects alpha in a new file, releases it with Esc and arms the demotion, as the debounce does when it reads the
  -- release: call what its timer calls, so that the demotion is pending when the terminal opens and no stall can end
  -- that first. Returns the buffer of the file, and a function that tells whether the demotion fired in a Claude
  -- terminal.
  local function release_alpha_with_demotion_pending()
    local path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "alpha beta gamma" }, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local file_buf = vim.api.nvim_get_current_buf()

    press("ve")
    settle(true) -- the debounce reads the selection
    press("<Esc>")
    selection._cancel_debounce_timer()
    selection.update_selection()
    assert.is_not_nil(selection.state.demotion_timer, "the demotion is not pending")

    local fired_in_terminal = false
    real_demotion = selection.handle_selection_demotion
    selection.handle_selection_demotion = function(...)
      fired_in_terminal = fired_in_terminal or selection.is_claude_terminal_buffer(vim.api.nvim_get_current_buf())
      return real_demotion(...)
    end
    return file_buf, function()
      return fired_in_terminal
    end
  end

  -- 50 ms: the demotion fires in the terminal. 200 ms: the debounce of the terminal's BufEnter cancels it first. Either
  -- way Claude holds the selection when you come back with the cursor where it was.
  for _, delay_ms in ipairs({ 50, 200 }) do
    it("keeps the selection when you enter a new terminal and come back (delay " .. delay_ms .. ")", function()
      start(delay_ms, { provider = "native", show_native_term_exit_tip = false })
      local file_buf, fired_in_terminal = release_alpha_with_demotion_pending()

      terminal.open()
      vim.cmd("stopinsert")
      local term_buf = vim.api.nvim_get_current_buf()
      assert.are.equal(term_buf, terminal.get_active_terminal_bufnr())
      settle()

      if delay_ms == 50 then
        assert.is_true(fired_in_terminal(), "the demotion did not fire in the terminal")
      end
      assert.are.equal("alpha", selection.get_latest_selection().text) -- held in the terminal

      vim.cmd("wincmd p")
      settle()

      assert.are.equal(file_buf, vim.api.nvim_get_current_buf())
      assert.are.equal("alpha", selection.get_latest_selection().text)
      assert.is_false(selection.get_latest_selection().selection.isEmpty)
    end)
  end

  -- With terminal.provider "none" the plugin registers no terminal, and a buffer is the Claude terminal only because its
  -- name says so. handle_selection_demotion must see that terminal too.
  it("keeps the selection when you enter a terminal that only its name says is Claude's (delay 50)", function()
    start(50, { provider = "none" })
    local file_buf, fired_in_terminal = release_alpha_with_demotion_pending()

    vim.cmd("terminal sh -c 'sleep 60' claude")
    vim.cmd("stopinsert")
    assert.is_nil(terminal.get_active_terminal_bufnr())
    assert.is_true(selection.is_claude_terminal_buffer(vim.api.nvim_get_current_buf()))
    settle()

    assert.is_true(fired_in_terminal(), "the demotion did not fire in the terminal")
    assert.are.equal("alpha", selection.get_latest_selection().text) -- held in the terminal

    vim.cmd("buffer " .. file_buf)
    settle()

    assert.are.equal(file_buf, vim.api.nvim_get_current_buf())
    assert.are.equal("alpha", selection.get_latest_selection().text)
    assert.is_false(selection.get_latest_selection().selection.isEmpty)
  end)
end)

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

  it("reports the cursor when an operator consumes a different selection, before you enter the terminal", function()
    start({ provider = "none" }, 50)
    open_file("alpha beta gamma")
    local file_buf = vim.api.nvim_get_current_buf()
    vim.cmd("terminal sh -c 'sleep 60' claude")
    local term_buf = vim.api.nvim_get_current_buf()
    vim.cmd("stopinsert")
    vim.cmd("buffer " .. file_buf)
    wait(200)
    select_and_release() -- Claude holds "alpha"

    press("$vd") -- a second selection, on the last character, consumed before the debounce
    vim.cmd("buffer " .. term_buf) -- and the Claude terminal, where the debounce does nothing
    wait(300)

    local held = selection.get_latest_selection()
    assert.is_true(held.selection.isEmpty)
    assert.are.equal(14, held.selection.start.character)
  end)

  -- The Claude terminal keeps a held selection, and Neovim fires TextChanged only for the current buffer. When the
  -- file changes while you are in the terminal (Claude rewrites it and Neovim reloads it, or a plugin edits it),
  -- Claude must not keep the text that is gone until you come back.
  describe("when the file of the held selection changes while you are in the Claude terminal", function()
    local function path_of(buf)
      return vim.api.nvim_buf_get_name(buf)
    end

    -- Neovim reloads a file whose modification time differs from the one it stored.
    local function rewrite_on_disk_and_reload(buf, line)
      local path = path_of(buf)
      vim.fn.writefile({ line }, path)
      local later = os.time() + 10
      (vim.uv or vim.loop).fs_utime(path, later, later)
      vim.cmd("checktime " .. buf)
    end

    it("reports the cursor when a plugin edits the text, and the file is not in a window", function()
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
      vim.api.nvim_buf_set_text(file_buf, 0, 0, 0, 6, {}) -- a plugin deletes "alpha "
      wait(300)

      assert.are.equal(term_buf, vim.api.nvim_get_current_buf())
      local held = selection.get_latest_selection()
      assert.is_true(held.selection.isEmpty)
      assert.are.equal(path_of(file_buf), held.filePath)
      assert.are.equal(4, held.selection.start.character) -- where you released the selection
    end)

    it("reports the cursor of the file's window when Neovim reloads the file", function()
      start({ provider = "none" }, 50)
      open_file("alpha beta gamma")
      local file_buf = vim.api.nvim_get_current_buf()
      local file_win = vim.api.nvim_get_current_win()
      vim.cmd("vsplit | terminal sh -c 'sleep 60' claude") -- the file stays in its own window
      local term_win = vim.api.nvim_get_current_win()
      vim.cmd("stopinsert")
      vim.api.nvim_set_current_win(file_win)
      wait(200)
      select_and_release()

      vim.api.nvim_set_current_win(term_win)
      vim.cmd("stopinsert")
      wait(300)
      rewrite_on_disk_and_reload(file_buf, "beta gamma")
      wait(300)

      assert.are.same({ "beta gamma" }, vim.api.nvim_buf_get_lines(file_buf, 0, -1, false))
      assert.are.equal(term_win, vim.api.nvim_get_current_win())
      local held = selection.get_latest_selection()
      assert.is_true(held.selection.isEmpty)
      assert.are.equal(path_of(file_buf), held.filePath)
      assert.are.equal(4, held.selection.start.character)
    end)

    -- :bunload! detaches the listener, and nvim_buf_attach cannot attach to an unloaded buffer. When the file is loaded
    -- again and selected from, a new listener must be attached.
    it("listens again when the file was unloaded and a new selection is read after it loads again", function()
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
      vim.cmd("bunload! " .. file_buf)
      wait(200)
      vim.cmd("buffer " .. file_buf)
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- Neovim put the cursor back where it was
      wait(200)
      select_and_release()
      vim.cmd("buffer " .. term_buf)
      vim.cmd("stopinsert")
      wait(300)

      vim.api.nvim_buf_set_text(file_buf, 0, 0, 0, 6, {}) -- a plugin deletes "alpha "
      wait(300)

      assert.are.equal(term_buf, vim.api.nvim_get_current_buf())
      assert.is_true(selection.get_latest_selection().selection.isEmpty)
    end)

    -- Neovim ignores what on_reload returns and keeps the listener. A listener that forgot its buffer there would let
    -- the next selection attach a second one, one more after every reload.
    it("keeps one listener on the file through reloads while Claude holds only a cursor", function()
      start({ provider = "none" }, 50)
      open_file("alpha beta gamma")
      local file_buf = vim.api.nvim_get_current_buf()
      local attached = 0
      local real_attach = vim.api.nvim_buf_attach
      vim.api.nvim_buf_attach = function(buf, ...)
        attached = attached + (buf == file_buf and 1 or 0)
        return real_attach(buf, ...)
      end

      local ok, err = pcall(function()
        for cycle = 1, 3 do
          vim.api.nvim_win_set_cursor(0, { 1, 0 })
          select_and_release()
          vim.cmd("enew") -- another file: the debounce replaces the selection with that buffer's cursor
          wait(300)
          assert.is_true(selection.get_latest_selection().selection.isEmpty)
          rewrite_on_disk_and_reload(file_buf, "alpha beta gamma, cycle " .. cycle) -- on_reload, nothing held
          wait(200)
          vim.cmd("buffer " .. file_buf)
          wait(200)
        end
      end)
      vim.api.nvim_buf_attach = real_attach
      assert(ok, err)

      assert.are.equal(1, attached)
    end)

    it("keeps the selection when a reload leaves its text in place", function()
      start({ provider = "none" }, 50)
      open_file("alpha beta gamma")
      local file_buf = vim.api.nvim_get_current_buf()
      local file_win = vim.api.nvim_get_current_win()
      vim.cmd("vsplit | terminal sh -c 'sleep 60' claude")
      local term_win = vim.api.nvim_get_current_win()
      vim.cmd("stopinsert")
      vim.api.nvim_set_current_win(file_win)
      wait(200)
      select_and_release()

      vim.api.nvim_set_current_win(term_win)
      vim.cmd("stopinsert")
      wait(300)
      rewrite_on_disk_and_reload(file_buf, "alpha beta gamma, and more")
      wait(300)

      assert.are.same({ "alpha beta gamma, and more" }, vim.api.nvim_buf_get_lines(file_buf, 0, -1, false))
      assert.are.equal("alpha", selection.get_latest_selection().text)

      -- The listener survives the reload: the next change is seen too.
      vim.api.nvim_buf_set_text(file_buf, 0, 0, 0, 6, {})
      wait(300)
      assert.is_true(selection.get_latest_selection().selection.isEmpty)
    end)
  end)

  -- A popup that wipes itself when you leave it: its buffer number is gone at the next event, and the plugin must
  -- neither raise nor keep the selection of a file you left.
  for _, kind in ipairs({ "bufhidden=wipe left with :buffer #", "nvim_buf_delete of the displayed buffer" }) do
    it("ends the selection without an error when the buffer you visited is wiped (" .. kind .. ")", function()
      start({ provider = "none" }, 50)
      open_file("alpha beta gamma")
      local file_buf = vim.api.nvim_get_current_buf()
      select_and_release()

      vim.cmd("enew")
      local scratch = vim.api.nvim_get_current_buf()
      vim.bo[scratch].buftype = "nofile"
      if kind:find("bufhidden") then
        vim.bo[scratch].bufhidden = "wipe"
      end
      wait(20) -- inside the debounce: the popup is closed before the plugin has looked at it

      assert.has_no.errors(function()
        if kind:find("bufhidden") then
          vim.cmd("buffer #")
        else
          vim.api.nvim_buf_delete(scratch, { force = true })
        end
      end)
      wait(400)

      assert.is_false(vim.api.nvim_buf_is_valid(scratch))
      assert.are.equal(file_buf, vim.api.nvim_get_current_buf())
      assert.is_true(selection.get_latest_selection().selection.isEmpty)
    end)
  end
end)

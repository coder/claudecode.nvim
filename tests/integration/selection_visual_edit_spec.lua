-- Real-Neovim check of what Claude holds when the buffer changes while you are in visual mode, through the real
-- start path with real autocmds and timers. The release of a selection (Esc) is skipped when an operator (d, c, >,
-- gU, ...) consumed it, because the '< and '> marks then point at text you never selected. A plugin's edit of
-- another line and a :write also move the buffer's changedtick, but they leave the selection on the screen: Claude
-- must get the selection, whether the release is quicker than the debounce (100 ms) or slower.
-- Busted's mock vim has no autocmds, so there these are pending; scripts/run_integration_tests_individually.sh runs
-- them in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("a visual selection released after the buffer changed, with the real plugin", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("a visual selection released after the buffer changed, with the real plugin", function()
  local claudecode = require("claudecode")
  local selection = require("claudecode.selection")
  local server = require("claudecode.server.init")
  local real_broadcast, real_config_dir, config_dir, sent

  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
  end

  -- Lets the real timers run: the debounce is 100 ms.
  local function wait(ms)
    vim.wait(ms, function()
      return false
    end, 5)
  end

  -- After an operator the plugin reports the cursor once its flush has run, and a busy host can delay that past any fixed
  -- wait (get_latest_selection() is nil until then). So wait until it holds a cursor, then let the debounce and the
  -- demotion run, so that a selection sent late would show.
  local function wait_for_cursor()
    local held = vim.wait(5000, function()
      local latest = selection.get_latest_selection()
      return latest ~= nil and latest.selection.isEmpty
    end, 5)
    assert.is_true(held, "the plugin holds a cursor after the operator")
    wait(200)
  end

  local function start()
    claudecode.setup({
      auto_start = false,
      log_level = "error",
      visual_demotion_delay_ms = 50,
      terminal_cmd = "sh -c 'sleep 60'",
      terminal = { provider = "none" },
    })
    assert.is_true(claudecode.start(false))
    sent = {}
    server.broadcast = function(method, params)
      table.insert(sent, { method = method, params = params })
      return true
    end
  end

  -- A saved file, so that it can be written. The buffer is not modified.
  local function open_file(lines)
    local path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile(lines, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.bo.swapfile = false
  end

  -- What Claude holds: the selection or the cursor that was sent last.
  local function held_text()
    local held = selection.get_latest_selection()
    return held and held.text
  end

  local function last_sent_text()
    local last = sent[#sent]
    return last and last.params and last.params.text
  end

  -- Nothing that Claude was sent after the operator (the messages from number `from` + 1 on) may carry the text that
  -- the marks point at after it. What was sent before is not the operator's doing: when something delays the keys
  -- past the debounce (a slow :write, a busy host), the debounce sends the selection that you are still making, and
  -- that is right. assert_is_the_selection checks that it is that selection, with its text and its range.
  local function sent_no_selection(from)
    for index = (from or 0) + 1, #sent do
      local params = sent[index].params
      if params and params.selection and not params.selection.isEmpty then
        return false, params.text
      end
    end
    return true
  end

  -- What Claude was told last must be a cursor: whatever the debounce sent before the operator, the plugin must have sent
  -- something after it that clears it, and not only forgotten it in its own state.
  local function assert_last_sent_is_a_cursor()
    local last = sent[#sent]
    assert.is_truthy(last, "something was sent")
    assert.is_true(last.params.selection.isEmpty, "the last selection_changed is a cursor")
  end

  -- Every selection (not a cursor) among the first `count` messages is `alpha` of the first line, which the tests select
  -- with `ve`: the text and the range, so a right text at a wrong range fails too.
  local function assert_is_the_selection(count)
    for index = 1, count do
      local params = sent[index].params
      if params and params.selection and not params.selection.isEmpty then
        assert.are.equal("alpha", params.text)
        assert.are.same({ line = 0, character = 0 }, params.selection.start)
        assert.are.same({ line = 0, character = 5 }, params.selection["end"])
      end
    end
  end

  -- A plugin edits the second line, without moving the selection on the first.
  local function plugin_edits_line_two()
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "second line changed" })
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
    pcall(vim.api.nvim_del_augroup_by_name, "ClaudeCodeSelectionVisualEditSpec")
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
  end)

  -- 20 ms is quicker than the debounce, so nothing was sent in visual mode. 300 ms is slower: the debounce sent
  -- the selection while you were still selecting.
  for _, delay_ms in ipairs({ 20, 300 }) do
    describe("with " .. delay_ms .. " ms between the steps", function()
      it("holds the selection after a plugin edits another line in visual mode", function()
        start()
        open_file({ "alpha beta gamma", "second line" })
        wait(50)

        press("ve")
        wait(delay_ms)
        plugin_edits_line_two()
        wait(delay_ms)
        press("<Esc>")
        wait(400)

        assert.are.equal("alpha", held_text())
        assert.are.equal("alpha", last_sent_text())
        assert.is_false(selection.get_latest_selection().selection.isEmpty)
      end)

      it("holds the selection after a plugin appends lines to the buffer in visual mode", function()
        start()
        open_file({ "alpha beta gamma", "second line" })
        wait(50)

        press("ve")
        wait(delay_ms)
        vim.api.nvim_buf_set_lines(0, 2, 2, false, { "appended", "lines" })
        wait(delay_ms)
        press("<Esc>")
        wait(400)

        assert.are.equal("alpha", held_text())
        assert.are.equal("alpha", last_sent_text())
      end)

      it("holds the selection after a :write of a modified buffer in visual mode", function()
        start()
        open_file({ "alpha beta gamma", "second line" })
        vim.api.nvim_buf_set_lines(0, 1, 2, false, { "second line, modified" })
        assert.is_true(vim.bo.modified)
        wait(50)

        press("ve")
        wait(delay_ms)
        local tick = vim.api.nvim_buf_get_changedtick(0)
        vim.cmd("silent write")
        assert.is_true(vim.api.nvim_buf_get_changedtick(0) ~= tick, "the write moves the changedtick")
        wait(delay_ms)
        press("<Esc>")
        wait(400)

        assert.are.equal("alpha", held_text())
        assert.are.equal("alpha", last_sent_text())
      end)
    end)
  end

  -- What the guard exists for: an operator consumes the selection, and the marks point at text you never selected.
  describe("when an operator consumes the selection", function()
    it("sends no selection for d (ved)", function()
      start()
      open_file({ "alpha beta gamma", "second line" })
      wait(50)

      press("ved")
      wait_for_cursor()

      assert.are.equal(" beta gamma", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
      assert.are.same({ true }, { sent_no_selection() })
      assert.is_true(selection.get_latest_selection().selection.isEmpty)
      assert_last_sent_is_a_cursor()
    end)

    it("sends no selection for c (vec)", function()
      start()
      open_file({ "alpha beta gamma", "second line" })
      wait(50)

      press("vecfoo<Esc>")
      wait_for_cursor()

      assert.are.equal("foo beta gamma", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
      assert.are.same({ true }, { sent_no_selection() })
      assert.is_true(selection.get_latest_selection().selection.isEmpty)
      assert_last_sent_is_a_cursor()
    end)

    it("sends no selection for a linewise > (Vj>)", function()
      start()
      open_file({ "alpha beta gamma", "second line", "third line" })
      wait(50)

      press("Vj>")
      wait_for_cursor()

      assert.are.same({ true }, { sent_no_selection() })
      assert.is_true(selection.get_latest_selection().selection.isEmpty)
      assert_last_sent_is_a_cursor()
    end)

    it("sends no selection for d after a plugin edited another line in visual mode", function()
      start()
      open_file({ "alpha beta gamma", "second line" })
      wait(50)

      press("ve")
      wait(20)
      plugin_edits_line_two()
      wait(20)
      local before_operator = #sent
      press("d")
      wait_for_cursor()

      assert.are.equal(" beta gamma", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
      assert.are.same({ true }, { sent_no_selection(before_operator) })
      assert_is_the_selection(before_operator)
      assert.is_true(selection.get_latest_selection().selection.isEmpty)
      assert_last_sent_is_a_cursor()
    end)

    it("sends no selection for d after a :write in visual mode", function()
      start()
      open_file({ "alpha beta gamma", "second line" })
      vim.api.nvim_buf_set_lines(0, 1, 2, false, { "second line, modified" })
      wait(50)

      press("ve")
      wait(20)
      vim.cmd("silent write")
      wait(20)
      local before_operator = #sent
      press("d")
      wait_for_cursor()

      assert.are.equal(" beta gamma", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
      assert.are.same({ true }, { sent_no_selection(before_operator) })
      assert_is_the_selection(before_operator)
      assert.is_true(selection.get_latest_selection().selection.isEmpty)
      assert_last_sent_is_a_cursor()
    end)
  end)

  -- A mapping runs its keys with no main-loop turn between them, so the check that the listener schedules for an edit
  -- has not run when the flush on Esc comes. The edit must be told apart from an operator's without waiting for it.
  describe("when the edit and the next key come in one typeahead", function()
    it("holds the selection after a mapping edits another line and presses Esc", function()
      start()
      open_file({ "alpha beta gamma", "second line" })
      wait(50)

      press("ve")
      wait(20)
      press("<Cmd>lua vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'second line changed' })<CR><Esc>")
      wait(400)

      assert.are.equal("second line changed", vim.api.nvim_buf_get_lines(0, 1, 2, false)[1])
      assert.are.equal("alpha", held_text())
      assert.are.equal("alpha", last_sent_text())
      assert.is_false(selection.get_latest_selection().selection.isEmpty)
    end)

    it("holds the selection after a mapping appends lines and presses Esc", function()
      start()
      open_file({ "alpha beta gamma", "second line" })
      wait(50)

      press("ve")
      wait(20)
      press("<Cmd>lua vim.api.nvim_buf_set_lines(0, 2, 2, false, { 'appended', 'lines' })<CR><Esc>")
      wait(400)

      assert.are.equal("alpha", held_text())
      assert.are.equal("alpha", last_sent_text())
    end)

    it("holds the selection after a mapping edits another line twice and presses Esc", function()
      start()
      open_file({ "alpha beta gamma", "second line" })
      wait(50)

      press("ve")
      wait(20)
      press(
        "<Cmd>lua vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'one' })<CR>"
          .. "<Cmd>lua vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'two' })<CR><Esc>"
      )
      wait(400)

      assert.are.equal("alpha", held_text())
      assert.are.equal("alpha", last_sent_text())
    end)

    it("holds the selection after a mapping writes the file and presses Esc", function()
      start()
      open_file({ "alpha beta gamma", "second line" })
      vim.api.nvim_buf_set_lines(0, 1, 2, false, { "second line, modified" })
      wait(50)

      press("ve")
      wait(20)
      press("<Cmd>silent write<CR><Esc>")
      wait(400)

      assert.are.equal("alpha", held_text())
      assert.are.equal("alpha", last_sent_text())
    end)

    -- The edit of a mapping is not the operator's: d after it still consumes the selection.
    it("sends no selection for d after a mapping edited another line", function()
      start()
      open_file({ "alpha beta gamma", "second line" })
      wait(50)

      press("ve")
      wait(20)
      local before_operator = #sent
      press("<Cmd>lua vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'second line changed' })<CR>d")
      wait_for_cursor()

      assert.are.equal(" beta gamma", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
      assert.are.same({ true }, { sent_no_selection(before_operator) })
      assert_is_the_selection(before_operator)
      assert.is_true(selection.get_latest_selection().selection.isEmpty)
      assert_last_sent_is_a_cursor()
    end)

    -- One typeahead for an operator and the next selection: the edit of the first must not count for the second.
    it("does not carry an operator's edit into the next selection", function()
      start()
      open_file({ "alpha beta gamma", "second line" })
      wait(50)

      press("vedwwve<Esc>")
      wait(400)

      assert.are.equal("gamma", held_text())
      assert.are.equal("gamma", last_sent_text())
    end)
  end)

  -- The schedule that checks an edit runs after the command or callback that made it. A key that is read first, with no
  -- main-loop turn before it, reaches the flush on Esc with an edit that nobody checked. (A key that a UI sends while a
  -- callback runs is another way to get there, but vim.wait gives it a main-loop turn first, so replays/ has it.)
  describe("when a key is read before the check of an edit", function()
    it("holds the selection when an autocmd edits another line as visual mode starts and Esc follows", function()
      start()
      open_file({ "alpha beta gamma", "second line" })
      local group = vim.api.nvim_create_augroup("ClaudeCodeSelectionVisualEditSpec", { clear = true })
      vim.api.nvim_create_autocmd("ModeChanged", {
        group = group,
        pattern = "n:v",
        once = true,
        callback = function()
          vim.api.nvim_buf_set_text(0, 1, 0, 1, 6, { "SECOND" })
        end,
      })
      wait(50)

      press("ve<Esc>")
      wait(400)
      vim.api.nvim_del_augroup_by_id(group)

      assert.are.equal("SECOND line", vim.api.nvim_buf_get_lines(0, 1, 2, false)[1])
      assert.are.equal("alpha", held_text())
      assert.are.equal("alpha", last_sent_text())
    end)
  end)

  -- The key listener checks the edit at the Esc, with visual mode still on. The schedule of that edit is still queued,
  -- and another ModeChanged handler that runs before the plugin's, and turns the main loop (vim.wait), runs it after
  -- Neovim ended visual mode and before the flush. That second check must find nothing to judge: judging the edit
  -- again, with visual mode over, takes the plugin's edit for an operator's.
  describe("when a queued check runs after visual mode ended and before the flush", function()
    it("holds the selection after a mapping edits another line and presses Esc", function()
      local group = vim.api.nvim_create_augroup("ClaudeCodeSelectionVisualEditSpec", { clear = true })
      vim.api.nvim_create_autocmd("ModeChanged", {
        group = group,
        pattern = "*:n",
        callback = function()
          vim.wait(0)
        end,
      })
      start() -- after the handler above, so that it runs first
      open_file({ "alpha beta gamma", "second line" })
      wait(50)

      press("ve")
      wait(20)
      press("<Cmd>lua vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'second line changed' })<CR><Esc>")
      wait(400)

      assert.are.equal("second line changed", vim.api.nvim_buf_get_lines(0, 1, 2, false)[1])
      assert.are.equal("alpha", held_text())
      assert.are.equal("alpha", last_sent_text())
      assert.is_false(selection.get_latest_selection().selection.isEmpty)
    end)
  end)

  it("does not carry an edit from one visual selection into the next", function()
    start()
    open_file({ "alpha beta gamma", "second line" })
    wait(50)

    press("ved") -- an operator consumes the first selection
    wait(200)
    press("ww")
    wait(200)
    press("ve") -- a second selection: the operator before it must not count
    wait(20)
    press("<Esc>")
    wait(400)

    assert.are.equal("gamma", held_text())
    assert.are.equal("gamma", last_sent_text())
  end)
end)

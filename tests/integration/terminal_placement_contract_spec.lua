if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("what the Claude terminal placement keeps from a plain swap", function()
    pending("needs a real Neovim")
  end)
  return
end

-- The providers and the diff put the Claude terminal into a split with `utils.win_set_buf_in_split`, and a plain
-- `nvim_win_set_buf` was what they called before. The cases below pin what a user of the plugin sees of that swap, in
-- shapes where a plain swap already works: the events Neovim fires and their order, an autosave on `BufHidden`, the
-- mode after a `startinsert` autocmd, the error of a raising autocmd, a terminal mapping that a `BufWinEnter` autocmd
-- installs, and the buffers that a swap refuses to wipe. They go through the public commands and `openDiff`, not through
-- the helper, so they pass on a tree that has no helper. The helper must keep every one of them. The answer of a pending
-- diff is in terminal_placement_diff_answers_spec.lua. Each case runs in its own headless Neovim, so a crash or a hang
-- fails one case, with its exit code, and not the whole file.
local child = require("tests.helpers.placement_child")

describe("what the Claude terminal placement keeps from a plain swap", function()
  local SCENARIOS = {
    events = [==[
local terminal = setup_native()
if P.path == "hidden" then
  terminal.open()
  hide_terminal(terminal)
end
record_events()
if P.path == "hidden" then
  vim.cmd("ClaudeCodeOpen")
else
  terminal.open()
end
result.events = events
result.mode = vim.fn.mode()
result.terminal_windows = #vim.fn.win_findbuf(terminal.get_active_terminal_bufnr())
finish()
]==],
    repair = [==[
local terminal = setup_native()
vim.cmd("topleft split")
local user_win = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(original)
local swapped = false
vim.api.nvim_create_autocmd("BufEnter", {
  callback = function(ev)
    if swapped or vim.api.nvim_buf_get_name(ev.buf) ~= "" or vim.bo[ev.buf].buftype ~= "" then
      return
    end
    swapped = true
    local scratch = vim.api.nvim_create_buf(true, true)
    labels[scratch] = "X"
    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), scratch)
    vim.api.nvim_win_set_buf(user_win, scratch)
  end,
})
record_events()
terminal.open()
result.events = events
result.terminal_windows = #vim.fn.win_findbuf(terminal.get_active_terminal_bufnr())
finish()
]==],
    diff_events = [==[
-- A diff in a new tab, with the Claude terminal shown. The events of the terminal buffer in the swap.
local terminal = setup_native()
terminal.open()
local term = terminal.get_active_terminal_bufnr()
vim.cmd("stopinsert")
vim.api.nvim_set_current_win(original)
local config = vim.deepcopy(require("claudecode.config").defaults)
config.diff_opts.open_in_new_tab = true
require("claudecode.diff").setup(config)
local tools = require("claudecode.tools.init")
tools.register_all()
_G.claude_deferred_responses = {}
record_events()
local call = tools.handle_invoke({ id = "c" }, {
  name = "openDiff",
  arguments = {
    old_file_path = dir .. "/a.txt",
    new_file_path = dir .. "/a.txt",
    new_file_contents = "alpha changed\n",
    tab_name = "d",
  },
})
result.deferred = call._deferred == true
result.terminal_events = {}
for _, event in ipairs(events) do
  if event:find(":T:", 1, true) then
    table.insert(result.terminal_events, event)
  end
end
result.tabs = vim.fn.tabpagenr("$")
result.terminal_windows = #vim.fn.win_findbuf(term)
finish()
]==],
    autosave = [==[
-- A hidden native terminal is shown while the file is edited. A BufLeave autocmd of the user's on the file closes the
-- window that the file was in, and a BufHidden autocmd saves the file.
local terminal = setup_native()
terminal.open()
hide_terminal(terminal)
if P.nohidden then
  vim.o.hidden = false
end
vim.api.nvim_buf_set_lines(file, 0, -1, false, { "UNSAVED USER EDIT" })
local counts = { BufWinLeave = 0, BufHidden = 0 }
vim.api.nvim_create_autocmd({ "BufWinLeave", "BufHidden" }, {
  buffer = file,
  callback = function(ev)
    counts[ev.event] = counts[ev.event] + 1
    if ev.event == "BufHidden" then
      vim.api.nvim_buf_call(ev.buf, function()
        vim.cmd("silent update")
      end)
    end
  end,
})
vim.api.nvim_create_autocmd("BufLeave", {
  buffer = file,
  once = true,
  nested = P.nested == true,
  callback = function()
    pcall(vim.api.nvim_win_close, original, false)
  end,
})
local ok, err = pcall(vim.cmd, "ClaudeCodeOpen")
result.ok = ok
result.err = ok and "" or tostring(err):sub(1, 120)
result.counts = counts
result.disk = vim.fn.readfile(dir .. "/a.txt")[1]
result.file_text = vim.api.nvim_buf_get_lines(file, 0, 1, false)[1]
result.terminal_windows = #vim.fn.win_findbuf(terminal.get_active_terminal_bufnr())
finish()
]==],
    startinsert = [==[
-- A user's startinsert autocmd for terminal windows. Where does the cursor end, in which mode, and where does a typed
-- key go? P.act is "diff" (openDiff in a new tab, the terminal shown) or "unfocused" (a hidden terminal shown without
-- focus). P.events is the event list of the autocmd.
local terminal = setup_native()
local tools = require("claudecode.tools.init")
local diff = require("claudecode.diff")
local config = vim.deepcopy(require("claudecode.config").defaults)
config.diff_opts.open_in_new_tab = true
diff.setup(config)
tools.register_all()
_G.claude_deferred_responses = {}
vim.defer_fn(function()
  terminal.open()
  vim.defer_fn(function()
    vim.cmd("stopinsert")
    if P.act == "unfocused" then
      hide_terminal(terminal)
    end
    vim.api.nvim_set_current_win(original)
    vim.defer_fn(function()
      vim.cmd("stopinsert")
      vim.api.nvim_create_autocmd(P.events, {
        pattern = "term://*",
        callback = function()
          vim.cmd("startinsert")
        end,
      })
      local proposal
      if P.act == "diff" then
        local call = tools.handle_invoke({ id = "c" }, {
          name = "openDiff",
          arguments = {
            old_file_path = dir .. "/a.txt",
            new_file_path = dir .. "/a.txt",
            new_file_contents = "alpha changed\n",
            tab_name = "wi",
          },
        })
        _G.claude_deferred_responses[tostring(call.coroutine)] = function() end
        proposal = diff._get_active_diffs()["wi"].new_buffer
      else
        terminal.ensure_visible()
      end
      vim.defer_fn(function()
        local current = vim.api.nvim_get_current_buf()
        result.mode = vim.fn.mode()
        result.current = current == proposal and "proposal" or current == file and "file" or "other"
        local target = proposal or file
        local before = vim.api.nvim_buf_get_lines(target, 0, 1, false)[1]
        vim.api.nvim_input("x")
        vim.defer_fn(function()
          result.before = before
          result.after = vim.api.nvim_buf_get_lines(target, 0, 1, false)[1]
          finish()
        end, 150)
      end, 300)
    end, 150)
  end, 200)
end, 20)
]==],
    raise = [==[
-- A BufLeave autocmd of the user's on the file raises an error (P.path "hidden" or "new").
local terminal = setup_native()
if P.path == "hidden" then
  terminal.open()
  hide_terminal(terminal)
end
vim.api.nvim_create_autocmd("BufLeave", {
  buffer = file,
  once = true,
  nested = P.nested == true,
  callback = function()
    error("USER BUFLEAVE ERROR")
  end,
})
local ok, err = pcall(vim.cmd, P.path == "hidden" and "ClaudeCodeOpen" or "ClaudeCode")
result.ok = ok
result.mentions_user_error = not ok and tostring(err):find("USER BUFLEAVE ERROR", 1, true) ~= nil
local term = terminal.get_active_terminal_bufnr()
result.terminal_windows = term and vim.api.nvim_buf_is_valid(term) and #vim.fn.win_findbuf(term) or 0
result.file_everywhere = true
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(first_tab)) do
  if vim.api.nvim_win_get_buf(win) ~= file then
    result.file_everywhere = false
  end
end
finish()
]==],
    cfg = [==[
-- A BufWinEnter autocmd for terminal buffers installs a mapping, and 'eventignore' lists the other four events that
-- Neovim fires when a window is entered. P.path is "hidden" or "new".
local terminal = setup_native()
if P.path == "hidden" then
  terminal.open()
  hide_terminal(terminal)
end
vim.api.nvim_create_autocmd("BufWinEnter", {
  pattern = "term://*",
  callback = function(ev)
    vim.keymap.set("t", "<F12>", "USER-ANSWER", { buffer = ev.buf })
  end,
})
vim.o.eventignore = "WinLeave,BufLeave,WinEnter,BufEnter"
local ok, err = pcall(vim.cmd, P.path == "hidden" and "ClaudeCodeOpen" or "ClaudeCode")
result.ok = ok
result.err = ok and "" or tostring(err):sub(1, 120)
local term = terminal.get_active_terminal_bufnr()
result.mapped = false
if term then
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(term, "t")) do
    if map.lhs == "<F12>" then
      result.mapped = true
    end
  end
end
finish()
]==],
    winenter = [==[
-- A WinEnter autocmd of the user's acts on the window that shows the terminal (P.act "close", "raise" or "swap"), or on
-- a new unnamed buffer (P.act "raise_unnamed"). P.path is "hidden" or "new".
local terminal = setup_native()
if P.path == "hidden" then
  terminal.open()
  hide_terminal(terminal)
end
local fired = 0
vim.api.nvim_create_autocmd("WinEnter", {
  callback = function()
    local current = vim.api.nvim_get_current_buf()
    local on_terminal = vim.bo[current].buftype == "terminal" or vim.b[current].claudecode_native_terminal
    local unnamed = vim.api.nvim_buf_get_name(current) == "" and vim.bo[current].buftype == ""
    if P.act == "raise_unnamed" then
      if unnamed then
        fired = fired + 1
        error("USER WINENTER ERROR")
      end
      return
    end
    if not on_terminal then
      return
    end
    fired = fired + 1
    if P.act == "close" then
      vim.api.nvim_win_close(vim.api.nvim_get_current_win(), false)
    elseif P.act == "raise" then
      error("USER WINENTER ERROR")
    end
  end,
})
local ok, err = pcall(vim.cmd, P.path == "hidden" and "ClaudeCodeOpen" or "ClaudeCode")
local term = terminal.get_active_terminal_bufnr()
result.ok = ok
result.err = ok and "" or tostring(err):sub(1, 140)
result.fired = fired
result.terminal_windows = term and vim.api.nvim_buf_is_valid(term) and #vim.fn.win_findbuf(term) or 0
local jobs = 0
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
    jobs = jobs + 1
  end
end
result.terminal_buffers = jobs
result.job_running = term and vim.api.nvim_buf_is_valid(term) and vim.b[term].terminal_job_id ~= nil
  and vim.fn.jobwait({ vim.b[term].terminal_job_id }, 0)[1] == -1 or false
finish()
]==],
    session = [==[
-- A session plugin: a BufLeave autocmd of the user's enters the first window, a WinEnter autocmd swaps the plugin's
-- own buffer into that window, and 'hidden' is off. The file has unsaved edits.
local terminal = setup_native()
terminal.open()
hide_terminal(terminal)
local term = terminal.get_active_terminal_bufnr()
local job = vim.b[term].terminal_job_id
vim.api.nvim_buf_set_lines(file, 0, -1, false, { "UNSAVED USER EDITS" })
local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(other, 0, -1, false, { "SESSION USER EDITS" })
vim.o.hidden = false
local switching = false
vim.api.nvim_create_autocmd("WinEnter", {
  callback = function()
    if switching and vim.api.nvim_get_current_win() == original then
      vim.api.nvim_win_set_buf(original, other)
    end
  end,
})
vim.api.nvim_create_autocmd("BufLeave", {
  buffer = file,
  once = true,
  nested = true,
  callback = function()
    switching = true
    vim.api.nvim_set_current_win(original)
    switching = false
  end,
})
local ok, err = pcall(vim.cmd, "ClaudeCodeOpen")
result.ok = ok
result.err = ok and "" or tostring(err):sub(1, 120)
result.job_running = vim.fn.jobwait({ job }, 10)[1] == -1
result.file_loaded = vim.api.nvim_buf_is_loaded(file)
result.file_text = vim.api.nvim_buf_is_loaded(file) and vim.api.nvim_buf_get_lines(file, 0, 1, false)[1] or "UNLOADED"
result.other_text = vim.api.nvim_buf_get_lines(other, 0, 1, false)[1]
finish()
]==],
    wipe = [==[
-- A BufHidden autocmd of the user's wipes the file that Neovim hides while the terminal is shown. Neovim refuses the
-- wipe of a buffer that it is hiding (E937). A BufLeave autocmd closes the other window of the file, so the split
-- shows the last window of the file.
local terminal = setup_native()
terminal.open()
hide_terminal(terminal)
local wipe = { ran = 0 }
vim.api.nvim_create_autocmd("BufHidden", {
  buffer = file,
  callback = function(ev)
    wipe.ran = wipe.ran + 1
    local wiped, err = pcall(vim.api.nvim_buf_delete, ev.buf, { force = true })
    wipe.ok = wiped
    wipe.err = wiped and "" or tostring(err):match("E%d+") or tostring(err):sub(1, 60)
  end,
})
vim.api.nvim_create_autocmd("BufLeave", {
  buffer = file,
  once = true,
  callback = function()
    pcall(vim.api.nvim_win_close, original, false)
  end,
})
local ok, err = pcall(vim.cmd, "ClaudeCodeOpen")
result.ok = ok
result.err = ok and "" or tostring(err)
result.wipe = wipe
result.file_valid = vim.api.nvim_buf_is_valid(file)
result.terminal_windows = #vim.fn.win_findbuf(terminal.get_active_terminal_bufnr())
finish()
]==],
  }

  local function run_to_end(name, case)
    return child.run_to_end(SCENARIOS[name], case)
  end

  describe("the events of the swap", function()
    -- A:O is the user's file in the window it was in, A:S the same file in the split, T the terminal buffer, X a
    -- scratch buffer of another plugin. The split's own WinLeave and WinEnter come from `:vsplit`.
    local SWAP_EVENTS = { "WinLeave:A:O", "WinEnter:A:S", "BufLeave:A:S", "BufEnter:T:S", "BufWinEnter:T:S" }

    it("are Neovim's own, in Neovim's order, for a new terminal", function()
      local result = run_to_end("events", { path = "new" })

      assert.same(SWAP_EVENTS, result.events)
      assert.equal(1, result.terminal_windows)
    end)

    it("are Neovim's own, in Neovim's order, for a hidden terminal that is shown again", function()
      local result = run_to_end("events", { path = "hidden" })

      assert.same(SWAP_EVENTS, result.events)
      assert.equal(1, result.terminal_windows)
    end)

    it(
      "are Neovim's own, in Neovim's order, for the swap after termopen, when another plugin swapped in a buffer",
      function()
        local result = run_to_end("repair")

        assert.same({
          "WinLeave:A:O",
          "WinEnter:A:S",
          "BufLeave:A:S",
          "BufEnter:T:S",
          "BufWinEnter:X:S",
          "BufLeave:X:S",
          "BufEnter:T:S",
          "BufWinEnter:T:S",
        }, result.events)
        assert.equal(1, result.terminal_windows)
      end
    )

    it("leave BufEnter out for the terminal of a diff in a new tab, and fire BufWinEnter once, in that tab", function()
      local result = run_to_end("diff_events")

      assert.is_true(result.deferred)
      assert.equal(2, result.tabs)
      assert.equal(2, result.terminal_windows)
      local entered, bufwinenter = 0, 0
      for _, event in ipairs(result.terminal_events) do
        if event == "BufEnter:T:N" then
          entered = entered + 1
        elseif event == "BufWinEnter:T:N" then
          bufwinenter = bufwinenter + 1
        end
      end
      assert.equal(0, entered, vim.inspect(result.terminal_events))
      assert.equal(1, bufwinenter, vim.inspect(result.terminal_events))
      assert.equal("BufWinEnter:T:N", result.terminal_events[1])
    end)
  end)

  describe("an autosave autocmd on BufHidden, when a BufLeave autocmd closes the other window of the file", function()
    local cases = {
      { name = "that is not nested", case = { nested = false } },
      { name = "that is nested", case = { nested = true } },
      { name = "that is not nested, with 'hidden' off", case = { nested = false, nohidden = true } },
    }
    for _, case in ipairs(cases) do
      it("saves the file once, when the autocmd " .. case.name, function()
        local result = run_to_end("autosave", case.case)

        assert.is_true(result.ok, result.err)
        assert.same({ BufWinLeave = 1, BufHidden = 1 }, result.counts)
        assert.equal("UNSAVED USER EDIT", result.disk)
        assert.equal("UNSAVED USER EDIT", result.file_text)
        assert.equal(1, result.terminal_windows)
      end)
    end
  end)

  describe("an autocmd of the user's that runs startinsert for terminal windows", function()
    local cases = {
      { name = "WinEnter, for a diff in a new tab", case = { act = "diff", events = { "WinEnter" } } },
      {
        name = "BufEnter and WinEnter, for a diff in a new tab",
        case = { act = "diff", events = { "BufEnter", "WinEnter" } },
      },
      {
        name = "WinEnter, for a hidden terminal that is shown without focus",
        case = { act = "unfocused", events = { "WinEnter" } },
      },
    }
    for _, case in ipairs(cases) do
      it("leaves the user in Normal mode, with a typed key editing the text, on " .. case.name, function()
        local result = run_to_end("startinsert", case.case)

        assert.equal("n", result.mode)
        assert.is_not.equal("other", result.current)
        assert.equal(result.before:sub(2), result.after, "a typed x must delete a character, not insert one")
      end)
    end
  end)

  describe("a BufLeave autocmd of the user's on the file that raises an error", function()
    local cases = {
      { name = "when a hidden terminal is shown", case = { path = "hidden" } },
      { name = "when a new terminal is opened", case = { path = "new" } },
      {
        name = "when a hidden terminal is shown, and the autocmd is nested",
        case = { path = "hidden", nested = true },
      },
    }
    for _, case in ipairs(cases) do
      it("fails the command with that error and shows no terminal, " .. case.name, function()
        local result = run_to_end("raise", case.case)

        assert.is_false(result.ok, "the command must fail, as a plain swap does")
        assert.is_true(result.mentions_user_error, "the error of the autocmd must reach the caller")
        assert.equal(0, result.terminal_windows)
        assert.is_true(result.file_everywhere, "every window of the tab must show the file")
      end)
    end
  end)

  it(
    "runs a BufWinEnter autocmd for terminal buffers when 'eventignore' lists WinLeave, BufLeave, WinEnter and BufEnter",
    function()
      local result = run_to_end("cfg", { path = "hidden" })

      assert.is_true(result.ok, result.err)
      assert.is_true(result.mapped, "the mapping that the BufWinEnter autocmd installs must exist")
    end
  )

  describe("a WinEnter autocmd of the user's that acts on the terminal", function()
    local cases = {
      { name = "closes the window of a hidden terminal that is shown", case = { path = "hidden", act = "close" } },
      { name = "closes the window of a new terminal", case = { path = "new", act = "close" } },
      { name = "raises on the terminal window of a hidden terminal", case = { path = "hidden", act = "raise" } },
      { name = "raises on a new unnamed buffer, for a new terminal", case = { path = "new", act = "raise_unnamed" } },
      {
        name = "raises on a new unnamed buffer, for a hidden terminal",
        case = { path = "hidden", act = "raise_unnamed" },
      },
    }
    for _, case in ipairs(cases) do
      it("never runs, and the terminal runs in one window, when it " .. case.name, function()
        local result = run_to_end("winenter", case.case)

        assert.is_true(result.ok, result.err)
        assert.equal(0, result.fired, "the placement fires no WinEnter for the terminal")
        assert.equal(1, result.terminal_windows)
        assert.equal(1, result.terminal_buffers)
        assert.is_true(result.job_running)
      end)
    end
  end)

  it("keeps the unsaved edits and the running terminal when a session plugin switches buffers on WinEnter", function()
    local result = run_to_end("session")

    assert.is_true(result.ok, result.err)
    assert.is_true(result.job_running)
    assert.is_true(result.file_loaded)
    assert.equal("UNSAVED USER EDITS", result.file_text)
    assert.equal("SESSION USER EDITS", result.other_text)
  end)

  it("refuses the wipe of the file that a BufHidden autocmd attempts while Neovim hides it (E937)", function()
    local result = run_to_end("wipe")

    assert.is_true(result.wipe.ran > 0, "the BufHidden autocmd must run")
    assert.is_false(result.wipe.ok, "Neovim must refuse the wipe")
    assert.is_true(result.file_valid, "the file's buffer must stay")
    assert.is_false(result.ok, "the swap fails as a plain swap does")
    assert.is_truthy(result.err:find("E937", 1, true), result.err)
  end)
end)

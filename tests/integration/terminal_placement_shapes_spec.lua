if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the terminal swap when a BufLeave autocmd enters another window, in other shapes", function()
    pending("needs a real Neovim")
  end)
  return
end

-- A BufLeave autocmd of the user's that enters another window during `nvim_win_set_buf` makes Neovim load the terminal
-- into that window. `utils.win_set_buf_in_split` fires `BufLeave` itself, in the split, and puts the cursor back in the
-- split when an autocmd moved it, so the terminal lands in the split. In the shapes below the window that the autocmd
-- enters, the options of the user's file and of the terminal buffer decide whether a buffer is unloaded, hidden or
-- refused with E37, so the helper must keep the outcome of a plain swap: the command works, the user's file is loaded
-- and still shows in its window, and the terminal runs in one window. Each case runs in its own headless Neovim, so a
-- crash or a hang fails one case, with its exit code, and not the whole file.
describe("the terminal swap when a BufLeave autocmd enters another window, in other shapes", function()
  local SCRIPT = [[
    local target, options = os.getenv("SWAP_TARGET"), os.getenv("SWAP_OPTIONS")
    local function has(option)
      return options:find(option, 1, true) ~= nil
    end
    vim.o.swapfile = false
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "alpha", "a2", "a3" }, dir .. "/a.txt")
    vim.fn.writefile({ "b1", "b2", "b3" }, dir .. "/b.txt")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    local file, start_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    require("claudecode").setup({
      auto_start = false,
      log_level = "error",
      terminal_cmd = "sleep 3600",
      terminal = { provider = "native" },
    })
    local terminal = require("claudecode.terminal")
    terminal.ensure_visible()
    terminal.simple_toggle()
    local term = terminal.get_active_terminal_bufnr()
    local job = vim.b[term].terminal_job_id

    -- The window that the BufLeave autocmd enters: the window of the user's file, or one that shows another file.
    local entered = start_win
    if target == "tab" then
      vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/b.txt"))
      entered = vim.api.nvim_get_current_win()
      vim.cmd("tabfirst")
    elseif target == "same-tab" then
      vim.cmd("topleft split " .. vim.fn.fnameescape(dir .. "/b.txt"))
      entered = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_set_current_win(start_win)

    vim.api.nvim_win_set_cursor(start_win, { 3, 1 })
    if has("wipe-file") then
      vim.bo[file].bufhidden = "wipe"
    end
    if has("modified") then
      vim.api.nvim_buf_set_lines(file, 0, -1, false, { "unsaved edit" })
    end
    if has("nohidden") then
      vim.o.hidden = false
    end
    if has("empty-bufhidden") then
      vim.bo[term].bufhidden = ""
    end
    if has("wipe-terminal") then
      -- A user's autocmd that sets the terminal's 'bufhidden' while the terminal is entered.
      vim.api.nvim_create_autocmd("BufEnter", {
        buffer = term,
        once = true,
        callback = function()
          vim.bo[term].bufhidden = "wipe"
        end,
      })
    end
    vim.api.nvim_create_autocmd("BufLeave", {
      buffer = file,
      once = true,
      callback = function()
        vim.api.nvim_set_current_win(entered)
      end,
    })

    local ok, err = pcall(vim.cmd, "ClaudeCode")

    local loaded = vim.api.nvim_buf_is_valid(file) and vim.api.nvim_buf_is_loaded(file)
    local result = {
      ok = ok,
      err = ok and "" or tostring(err):match("E%d+:[^\n]*") or tostring(err),
      file_loaded = loaded,
      file_lines = loaded and vim.api.nvim_buf_get_lines(file, 0, -1, false) or {},
      start_win_shows_file = vim.api.nvim_win_is_valid(start_win) and vim.api.nvim_win_get_buf(start_win) == file,
      terminal_valid = vim.api.nvim_buf_is_valid(term),
      job_running = vim.fn.jobwait({ job }, 100)[1] == -1,
      terminal_windows = vim.api.nvim_buf_is_valid(term) and #vim.fn.win_findbuf(term) or 0,
      terminal_in_entered_window = vim.api.nvim_buf_is_valid(term) and vim.fn.win_findbuf(term)[1] == entered,
    }
    vim.fn.writefile({ vim.json.encode(result) }, os.getenv("SWAP_OUT"))
    vim.cmd("qa!")
  ]]

  local DIFF_SCRIPT = [[
    vim.o.swapfile = false
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "alpha" }, dir .. "/a.txt")
    vim.fn.writefile({ "b1", "b2", "b3" }, dir .. "/b.txt")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    local start_win = vim.api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    local terminal_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, terminal_buf)
    vim.fn.termopen({ "sleep", "60" })
    vim.cmd("wincmd p")
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return terminal_buf
      end,
      ensure_visible = function() end,
    }
    local config = vim.deepcopy(require("claudecode.config").defaults)
    config.diff_opts.open_in_new_tab = true
    require("claudecode.diff").setup(config)
    require("claudecode.tools.init").register_all()
    _G.claude_deferred_responses = {}

    -- A BufEnter autocmd for the terminal buffer, as Snacks' auto_insert is: it can queue an insert that starts in the
    -- window the cursor ends in.
    local terminal_bufenter_runs = 0
    vim.api.nvim_create_autocmd("BufEnter", {
      buffer = terminal_buf,
      callback = function()
        terminal_bufenter_runs = terminal_bufenter_runs + 1
      end,
    })

    -- A BufLeave autocmd of the user's that enters their window in the first tab, or that closes the window it runs in,
    -- once the new tab has its two windows.
    local armed = os.getenv("SWAP_ARMED") ~= "0"
    local closes = os.getenv("SWAP_CLOSE") == "1"
    -- SWAP_ENTER_CLOSE: enter the window in the first tab, then close the split. SWAP_SHOWS_OTHER: show a changed
    -- buffer with 'bufhidden' wipe in the split, which `buffer!` would wipe with its text.
    local enters_closes = os.getenv("SWAP_ENTER_CLOSE") == "1"
    local closes_tab = os.getenv("SWAP_CLOSE_TAB") == "1"
    local shows_other = os.getenv("SWAP_SHOWS_OTHER") == "1"
    local other_buf
    vim.api.nvim_create_autocmd("BufLeave", {
      callback = function()
        if armed and vim.fn.tabpagenr() == 2 and #vim.api.nvim_tabpage_list_wins(0) == 2 then
          armed = false
          if closes then
            vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
          elseif closes_tab then
            local windows = vim.api.nvim_tabpage_list_wins(0)
            vim.api.nvim_set_current_win(start_win)
            for _, win in ipairs(windows) do
              pcall(vim.api.nvim_win_close, win, true)
            end
          elseif enters_closes then
            local split = vim.api.nvim_get_current_win()
            vim.api.nvim_set_current_win(start_win)
            vim.api.nvim_win_close(split, true)
          elseif shows_other then
            other_buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "unsaved X text" })
            vim.bo[other_buf].bufhidden = "wipe"
            vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), other_buf)
          else
            vim.api.nvim_set_current_win(start_win)
          end
        end
      end,
    })
    local path = dir .. "/b.txt"
    local response = require("claudecode.tools.init").handle_invoke({ id = "other_shapes_spec_client" }, {
      name = "openDiff",
      arguments = { old_file_path = path, new_file_path = path, new_file_contents = "new\n", tab_name = "shape" },
    })
    local file_buf = vim.fn.bufnr(dir .. "/a.txt")
    local result = {
      deferred = response._deferred == true,
      err = response.error and tostring(response.error.data):sub(-120) or "",
      armed_used = not armed,
      tabs = vim.fn.tabpagenr("$"),
      start_win_shows_file = vim.api.nvim_win_get_buf(start_win) == file_buf,
      terminal_bufenter_runs = terminal_bufenter_runs,
      -- The diff gives the terminal buffer a BufEnter autocmd that enters terminal mode, when it shows the terminal.
      auto_enter_autocmds = #vim.tbl_filter(function(autocmd)
        return (autocmd.desc or ""):find("Auto-enter terminal mode", 1, true) ~= nil
      end, vim.api.nvim_get_autocmds({ buffer = terminal_buf, event = "BufEnter" })),
      terminal_in_new_tab = vim.api.nvim_list_tabpages()[2] ~= nil
        and vim.tbl_contains(
          vim.tbl_map(vim.api.nvim_win_get_buf, vim.api.nvim_tabpage_list_wins(vim.api.nvim_list_tabpages()[2])),
          terminal_buf
        ),
      current_tab = vim.fn.tabpagenr(),
      other_windows = other_buf and vim.api.nvim_buf_is_valid(other_buf) and #vim.fn.win_findbuf(other_buf) or 0,
      other_lines = other_buf
          and vim.api.nvim_buf_is_valid(other_buf)
          and vim.api.nvim_buf_is_loaded(other_buf)
          and vim.api.nvim_buf_get_lines(other_buf, 0, -1, false)
        or {},
    }
    -- The proposal of the diff is a buffer whose name ends in "(proposed)". Which tab shows it?
    for index, tab in ipairs(vim.api.nvim_list_tabpages()) do
      local shows_proposal = false
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find("(proposed)", 1, true) then
          shows_proposal = true
        end
      end
      result["proposal_in_tab_" .. index] = shows_proposal
    end
    vim.fn.writefile({ vim.json.encode(result) }, os.getenv("SWAP_OUT"))
    vim.cmd("qa!")
  ]]

  ---Runs `script` in a headless Neovim. Returns its exit code (nil after a hang of 20 s) and the result it wrote.
  local function run_child(script, env)
    local script_file, out = vim.fn.tempname() .. ".lua", vim.fn.tempname()
    vim.fn.writefile(vim.split(script, "\n"), script_file)
    env.SWAP_OUT = out
    local exit_code
    local job = vim.fn.jobstart({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-n",
      "--cmd",
      "set rtp^=" .. vim.fn.getcwd(),
      "-c",
      "luafile " .. vim.fn.fnameescape(script_file),
    }, {
      env = env,
      on_exit = function(_, code)
        exit_code = code
      end,
    })
    assert.is_true(job > 0, "could not start a child Neovim")
    if not vim.wait(20000, function()
      return exit_code ~= nil
    end, 50) then
      vim.fn.jobstop(job)
    end
    local result
    if vim.fn.filereadable(out) == 1 then
      result = vim.json.decode(table.concat(vim.fn.readfile(out), "\n"))
    end
    vim.fn.delete(script_file)
    vim.fn.delete(out)
    return exit_code, result
  end

  ---What a plain swap gives, and the terminal in its split, not in the window that the autocmd entered.
  local function expect_plain_swap_outcome(case, file_lines)
    local exit_code, result = run_child(SCRIPT, { SWAP_TARGET = case.target, SWAP_OPTIONS = case.options })

    assert.equal(0, exit_code, "Neovim must survive (nil is a hang): " .. vim.inspect(result))
    assert.is_not_nil(result, "the case wrote no result")
    assert.is_true(result.ok, "the command must not fail: " .. result.err)
    assert.is_true(result.file_loaded, "the user's file must stay loaded")
    assert.same(file_lines or { "alpha", "a2", "a3" }, result.file_lines)
    assert.is_true(result.terminal_valid, "the terminal buffer must stay")
    assert.is_true(result.job_running, "the terminal job must keep running")
    assert.equal(1, result.terminal_windows)
    assert.is_true(result.start_win_shows_file, "the window that the terminal was opened from must keep the file")
    assert.is_false(
      result.terminal_in_entered_window,
      "the terminal must not be in the window that the autocmd entered"
    )
  end

  local cases = {
    {
      name = "a window of another tab, with the user's file wiped once hidden",
      target = "tab",
      options = "wipe-file",
    },
    {
      name = "a window of another tab, with 'nohidden' and an unsaved edit in the user's file",
      target = "tab",
      options = "nohidden,modified",
      lines = { "unsaved edit" },
    },
    { name = "a window of another tab, with 'nohidden'", target = "tab", options = "nohidden" },
    { name = "a window of the same tab, with 'nohidden'", target = "same-tab", options = "nohidden" },
    {
      name = "a window of the same tab, with the user's file wiped once hidden",
      target = "same-tab",
      options = "wipe-file",
    },
  }
  for _, case in ipairs(cases) do
    it("keeps the user's file and the terminal when the autocmd enters " .. case.name, function()
      expect_plain_swap_outcome(case, case.lines)
    end)
  end

  it("keeps the running terminal when a BufEnter autocmd of the user's sets its 'bufhidden' to wipe", function()
    expect_plain_swap_outcome({ target = "start", options = "wipe-terminal" })
  end)

  it("keeps the running terminal when 'hidden' is not set and its 'bufhidden' is empty", function()
    expect_plain_swap_outcome({ target = "start", options = "nohidden,empty-bufhidden" })
  end)

  it("opens a diff in a new tab when a BufLeave autocmd enters the user's window in the first tab", function()
    local exit_code, result = run_child(DIFF_SCRIPT, {})

    assert.equal(0, exit_code, "Neovim must survive (nil is a hang): " .. vim.inspect(result))
    assert.is_not_nil(result, "the case wrote no result")
    assert.is_true(result.armed_used, "the autocmd must have run during the swap, or the test proves nothing")
    assert.is_true(result.deferred, "openDiff must open: " .. result.err)
    assert.equal(2, result.tabs)
    assert.is_true(result.start_win_shows_file, "the window in the first tab must keep the file")
    assert.is_true(result.terminal_in_new_tab, "the terminal must be in a window of the new tab")
    assert.equal(1, result.auto_enter_autocmds)
  end)

  -- Without the autocmd above, Neovim fires BufEnter for the terminal buffer when the cursor enters the split, and a
  -- handler of that buffer, as Snacks' auto_insert is, can queue an insert that starts in the window the cursor ends in.
  it("opens a diff in a new tab with no terminal when a BufLeave autocmd closes the terminal's split", function()
    local exit_code, result = run_child(DIFF_SCRIPT, { SWAP_CLOSE = "1" })

    assert.equal(0, exit_code, "Neovim must survive (nil is a hang): " .. vim.inspect(result))
    assert.is_not_nil(result, "the case wrote no result")
    assert.is_true(result.armed_used, "the autocmd must have run during the swap, or the test proves nothing")
    assert.is_true(result.deferred, "openDiff must open: " .. result.err)
    assert.equal(2, result.tabs)
    assert.is_true(result.start_win_shows_file, "the window in the first tab must keep the file")
    assert.is_false(result.terminal_in_new_tab, "the terminal's split is closed, so the new tab has no terminal window")
    assert.equal(
      0,
      result.auto_enter_autocmds,
      "no BufEnter autocmd may be left for a window that never showed the terminal"
    )
  end)

  it(
    "builds the diff in the new tab, with no terminal, when a BufLeave autocmd enters the first tab and closes the split",
    function()
      local exit_code, result = run_child(DIFF_SCRIPT, { SWAP_ENTER_CLOSE = "1" })

      assert.equal(0, exit_code, "Neovim must survive (nil is a hang): " .. vim.inspect(result))
      assert.is_not_nil(result, "the case wrote no result")
      assert.is_true(result.armed_used, "the autocmd must have run during the swap, or the test proves nothing")
      assert.is_true(result.deferred, "openDiff must open: " .. result.err)
      assert.equal(2, result.tabs)
      assert.is_true(result.start_win_shows_file, "the window in the first tab must keep the file")
      assert.is_false(
        result.terminal_in_new_tab,
        "the terminal's split is closed, so the new tab has no terminal window"
      )
      assert.is_true(result.proposal_in_tab_2, "the diff must be built in the new tab")
      assert.is_false(result.proposal_in_tab_1, "the user's own tab must not get the diff windows")
      assert.equal(2, result.current_tab)
    end
  )

  it("builds the diff in the one tab that is left when a BufLeave autocmd closes the new tab", function()
    local exit_code, result = run_child(DIFF_SCRIPT, { SWAP_CLOSE_TAB = "1" })

    assert.equal(0, exit_code, "Neovim must survive (nil is a hang): " .. vim.inspect(result))
    assert.is_not_nil(result, "the case wrote no result")
    assert.is_true(result.armed_used, "the autocmd must have run during the swap, or the test proves nothing")
    assert.is_true(result.deferred, "openDiff must open: " .. result.err)
    assert.equal(1, result.tabs)
    assert.is_true(result.start_win_shows_file, "the window in the first tab must keep the file")
    assert.is_true(result.proposal_in_tab_1, "the diff must be built in the tab that is left")
  end)

  it(
    "builds the diff in the new tab, with the terminal, and keeps the changed buffer that a BufLeave autocmd showed in the split",
    function()
      local exit_code, result = run_child(DIFF_SCRIPT, { SWAP_SHOWS_OTHER = "1" })

      assert.equal(0, exit_code, "Neovim must survive (nil is a hang): " .. vim.inspect(result))
      assert.is_not_nil(result, "the case wrote no result")
      assert.is_true(result.armed_used, "the autocmd must have run during the swap, or the test proves nothing")
      assert.is_true(result.deferred, "openDiff must open: " .. result.err)
      assert.equal(2, result.tabs)
      assert.is_true(result.terminal_in_new_tab, "the terminal must be in a window of the new tab")
      assert.same({ "unsaved X text" }, result.other_lines, "the text of that buffer must be kept")
      assert.equal(0, result.other_windows, "that buffer is hidden")
      assert.is_true(result.proposal_in_tab_2, "the diff must be built in the new tab")
      assert.is_false(result.proposal_in_tab_1)
    end
  )

  it("opens a diff in a new tab without running a BufEnter autocmd of the terminal buffer", function()
    local exit_code, result = run_child(DIFF_SCRIPT, { SWAP_ARMED = "0" })

    assert.equal(0, exit_code, "Neovim must survive (nil is a hang): " .. vim.inspect(result))
    assert.is_not_nil(result, "the case wrote no result")
    assert.is_true(result.deferred, "openDiff must open: " .. result.err)
    assert.is_true(result.terminal_in_new_tab, "the terminal must be in a window of the new tab")
    assert.equal(0, result.terminal_bufenter_runs, "no BufEnter autocmd of the terminal buffer may run for the swap")
  end)
end)

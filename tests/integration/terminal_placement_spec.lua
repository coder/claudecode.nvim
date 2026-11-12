if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the terminal's placement in its own split", function()
    pending("needs a real Neovim")
  end)
  return
end

-- `nvim_win_set_buf` runs the BufLeave autocmds of the buffer it replaces inside the call. When one of them enters
-- another window, Neovim loads the new buffer into that window, even though the call names another one. The providers
-- put the terminal into the split they made with `utils.win_set_buf_in_split`, which runs those events before the swap,
-- so such an autocmd only moves the cursor. The swap itself fires the events that a plain swap fires, in the same order.
describe("the terminal's placement in its own split", function()
  local chan

  local function call(code, ...)
    return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
  end

  local function start_child()
    chan = vim.fn.jobstart({
      vim.v.progpath,
      "--embed",
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "--cmd",
      "set rtp^=" .. vim.fn.getcwd(),
    }, { rpc = true })
    assert.is_true(chan > 0, "could not start a child Neovim")
    call([[
      vim.o.swapfile = false
      _G.dir = vim.fn.tempname()
      vim.fn.mkdir(_G.dir, "p")
      vim.fn.writefile({ "alpha", "beta" }, _G.dir .. "/a.txt")
      vim.fn.writefile({ "one", "two" }, _G.dir .. "/other.txt")
      vim.cmd("edit " .. vim.fn.fnameescape(_G.dir .. "/a.txt"))
      require("claudecode").setup({
        auto_start = false,
        log_level = "error",
        terminal_cmd = "sleep 3600",
        terminal = { provider = "native" },
      })
    ]])
  end

  ---A second window of the user's above the current one. It shows the same file, with an edit, as the window that the
  ---provider splits. The cursor stays in the window it was in.
  local function open_user_window()
    return call([[
      local start = vim.api.nvim_get_current_win()
      vim.cmd("topleft split")
      _G.user_win = vim.api.nvim_get_current_win()
      _G.user_buf = vim.api.nvim_win_get_buf(_G.user_win)
      vim.api.nvim_buf_set_lines(_G.user_buf, 0, -1, false, { "user changed one", "user kept two" })
      vim.api.nvim_set_current_win(start)
      return vim.api.nvim_buf_get_lines(_G.user_buf, 0, -1, false)
    ]])
  end

  ---A BufLeave autocmd of the user's that enters their window, once or every time.
  local function arm_bufleave_autocmd(every_time)
    call(
      [[
      local every_time = ...
      _G.runs = 0
      vim.api.nvim_create_autocmd("BufLeave", {
        once = not every_time,
        callback = function()
          _G.runs = _G.runs + 1
          if vim.api.nvim_get_current_win() ~= _G.user_win then
            vim.api.nvim_set_current_win(_G.user_win)
          end
        end,
      })
    ]],
      every_time
    )
  end

  ---Another plugin's BufEnter swaps a scratch buffer of its own into the split and into the user's window when the new
  ---terminal buffer is entered, so the swap that follows `termopen` runs, and the user's window shows the same buffer
  ---as the split. Only the BufLeave of that scratch buffer enters the user's window.
  local function arm_scratch_swap(every_time)
    call(
      [[
      local every_time = ...
      _G.runs = 0
      local swapped = false
      vim.api.nvim_create_autocmd("BufEnter", {
        callback = function(ev)
          if swapped or vim.api.nvim_buf_get_name(ev.buf) ~= "" or vim.bo[ev.buf].buftype ~= "" then
            return
          end
          swapped = true
          local scratch = vim.api.nvim_create_buf(true, true)
          vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), scratch)
          vim.api.nvim_win_set_buf(_G.user_win, scratch)
          _G.user_buf = scratch
          vim.api.nvim_create_autocmd("BufLeave", {
            buffer = scratch,
            once = not every_time,
            callback = function()
              _G.runs = _G.runs + 1
              if vim.api.nvim_get_current_win() ~= _G.user_win then
                vim.api.nvim_set_current_win(_G.user_win)
              end
            end,
          })
        end,
      })
    ]],
      every_time
    )
  end

  local function hide_terminal()
    call([[
      local terminal = require("claudecode.terminal")
      terminal.open()
      for _, win in ipairs(vim.fn.win_findbuf(terminal.get_active_terminal_bufnr())) do
        vim.api.nvim_win_close(win, false)
      end
    ]])
  end

  local function terminal_windows()
    return call([[
      local terminal = require("claudecode.terminal")
      local buf = terminal.get_active_terminal_bufnr()
      return buf and vim.fn.win_findbuf(buf) or {}
    ]])
  end

  local function expect_user_window_kept(lines)
    local state = call([[
      local valid = vim.api.nvim_win_is_valid(_G.user_win)
      return {
        valid = valid,
        shows_user_buf = valid and vim.api.nvim_win_get_buf(_G.user_win) == _G.user_buf,
        user_win = _G.user_win,
        lines = vim.api.nvim_buf_get_lines(_G.user_buf, 0, -1, false),
        runs = _G.runs,
      }
    ]])
    local windows = terminal_windows()

    assert.is_true(state.valid)
    assert.is_true(state.runs >= 1, "the autocmd must have run during the swap, or the test proves nothing")
    assert.is_true(state.shows_user_buf, "the window of the user's file must keep showing it")
    assert.same(lines, state.lines)
    assert.equal(1, #windows, "the terminal must be in exactly one window")
    assert.not_equal(state.user_win, windows[1], "the terminal must not be in the user's window")
    return state
  end

  after_each(function()
    if chan then
      pcall(vim.rpcrequest, chan, "nvim_exec_lua", "pcall(require('claudecode.terminal').close)", {})
      vim.fn.jobstop(chan)
      vim.fn.jobwait({ chan }, 3000)
      chan = nil
    end
  end)

  for _, every_time in ipairs({ false, true }) do
    local autocmd = every_time and "a BufLeave autocmd that runs every time" or "a run-once BufLeave autocmd"

    it("shows a hidden terminal in its own split, with " .. autocmd .. " that enters the user's window", function()
      start_child()
      hide_terminal()
      local lines = open_user_window()
      arm_bufleave_autocmd(every_time)

      call([[require("claudecode.terminal").ensure_visible()]])

      expect_user_window_kept(lines)
    end)

    it("opens a new terminal in its own split, with " .. autocmd .. " that enters the user's window", function()
      start_child()
      local lines = open_user_window()
      arm_bufleave_autocmd(every_time)

      call([[require("claudecode.terminal").ensure_visible()]])

      expect_user_window_kept(lines)
    end)

    it(
      "shows the new terminal in its own split when a BufEnter autocmd swapped another buffer into it, with " .. autocmd,
      function()
        start_child()
        open_user_window()
        arm_scratch_swap(every_time)

        call([[require("claudecode.terminal").ensure_visible()]])

        -- The user's window now shows the scratch buffer of the other plugin, which has one empty line.
        expect_user_window_kept({ "" })
      end
    )
  end

  it(
    "keeps the user's file in the window it was split from, also when the file's buffer is wiped once hidden",
    function()
      -- The buffer goes only to the split while the terminal is in the other window, so a swap that moved the terminal
      -- into the split first would wipe it, and the other window could not get it back.
      start_child()
      local lines = call([[
      _G.user_win = vim.api.nvim_get_current_win()
      _G.user_buf = vim.api.nvim_win_get_buf(_G.user_win)
      vim.bo[_G.user_buf].bufhidden = "wipe"
      return vim.api.nvim_buf_get_lines(_G.user_buf, 0, -1, false)
    ]])
      arm_bufleave_autocmd(false)

      call([[require("claudecode.terminal").ensure_visible()]])

      expect_user_window_kept(lines)
    end
  )

  describe("fires the events of a plain swap", function()
    ---Runs `swap` for a split of a file in a tab of its own, once as a plain `nvim_win_set_buf` (`use_helper` false) and
    ---once as the helper, with a logger on the events a swap fires. `prepare` gets the file, the terminal buffer, the
    ---split and the window that the file also shows in, and can add autocmds and set options. `context` adds the
    ---current window and buffer to each log line, for a swap that no autocmd redirects.
    local function logs(prepare, opts)
      start_child()
      return call(
        [[
        local prepare, opts = ...
        prepare = load(prepare)
        local utils = require("claudecode.utils")
        local function run(use_helper)
          vim.cmd("tabnew")
          local file = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_win_set_buf(0, file)
          local first = vim.api.nvim_get_current_win()
          vim.cmd("vsplit")
          local split = vim.api.nvim_get_current_win()
          local terminal = vim.api.nvim_create_buf(true, false)
          local roles = { [file] = "file", [terminal] = "terminal" }
          local function role(buf)
            return roles[buf] or "other"
          end
          local function index(win)
            for i, other in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
              if other == win then
                return i
              end
            end
            return -1
          end
          local group = vim.api.nvim_create_augroup("swap_events_" .. tostring(use_helper), { clear = true })
          prepare(file, terminal, split, first, group)
          local log = {}
          vim.api.nvim_create_autocmd(
            { "BufLeave", "BufEnter", "BufWinEnter", "BufWinLeave", "BufHidden", "WinEnter", "WinLeave" },
            {
              group = group,
              callback = function(event)
                local line = event.event .. "@" .. role(event.buf)
                if opts.context then
                  line = line .. " in window " .. index(vim.api.nvim_get_current_win())
                    .. " showing " .. role(vim.api.nvim_get_current_buf())
                end
                table.insert(log, line)
              end,
            }
          )
          if use_helper then
            utils.win_set_buf_in_split(split, terminal, { ignore_bufenter = opts.ignore_bufenter })
          else
            local saved = vim.o.eventignore
            if opts.ignore_bufenter then
              vim.o.eventignore = "BufEnter"
            end
            vim.api.nvim_win_set_buf(split, terminal)
            vim.o.eventignore = saved
          end
          vim.api.nvim_clear_autocmds({ group = group })
          return {
            log = log,
            split_shows = role(vim.api.nvim_win_get_buf(split)),
            first_shows = vim.api.nvim_win_is_valid(first) and role(vim.api.nvim_win_get_buf(first)) or "closed",
            current = index(vim.api.nvim_get_current_win()),
          }
        end
        return { plain = run(false), helper = run(true) }
      ]],
        prepare,
        opts or {}
      )
    end

    ---A swap that no autocmd redirects gives the same events, each with the same current window and buffer.
    local function expect_same(prepare, opts)
      local result = logs(prepare, vim.tbl_extend("force", { context = true }, opts or {}))

      assert.equal("terminal", result.plain.split_shows)
      assert.is_true(#result.plain.log > 0, "the swap must fire events, or the test proves nothing")
      assert.same(result.plain.log, result.helper.log)
      assert.same({ split_shows = "terminal", first_shows = result.plain.first_shows }, {
        split_shows = result.helper.split_shows,
        first_shows = result.helper.first_shows,
      })
      assert.equal(result.plain.current, result.helper.current)
    end

    it("when the buffer it replaces also shows in another window", function()
      expect_same("")
    end)

    it("when the buffer it replaces shows in no other window and stays loaded", function()
      expect_same([[
        local file, _, _, first = ...
        vim.api.nvim_win_close(first, true)
        vim.bo[file].bufhidden = "hide"
      ]])
    end)

    it("when the buffer it replaces shows in no other window and 'hidden' is on", function()
      expect_same([[
        local _, _, _, first = ...
        vim.o.hidden = true
        vim.api.nvim_win_close(first, true)
      ]])
    end)

    it("when the buffer it replaces is unloaded by the swap", function()
      expect_same([[
        local _, _, _, first = ...
        vim.o.hidden = false
        vim.api.nvim_win_close(first, true)
      ]])
    end)

    it("when BufEnter autocmds of the user's run for the terminal buffer", function()
      expect_same([[
        local _, terminal, _, _, group = ...
        vim.api.nvim_create_autocmd("BufEnter", {
          group = group,
          buffer = terminal,
          callback = function() end,
        })
      ]])
    end)

    it("without BufEnter, as a swap that ignores BufEnter fires them", function()
      expect_same("", { ignore_bufenter = true })
    end)

    it("when an autocmd of the user's saves the file as the cursor leaves it", function()
      local result = logs(
        [[
        local file, _, _, _, group = ...
        vim.api.nvim_buf_set_lines(file, 0, -1, false, { "user edit" })
        vim.api.nvim_buf_set_name(file, _G.dir .. "/saved-" .. file .. ".txt")
        vim.api.nvim_create_autocmd("BufLeave", {
          group = group,
          buffer = file,
          callback = function()
            vim.cmd("silent! update")
          end,
        })
      ]],
        { context = true }
      )

      assert.same(result.plain.log, result.helper.log)
    end)

    it("with the same events, in the same order, when a BufLeave autocmd enters another window", function()
      local result = logs(
        [[
        local file, _, _, first, group = ...
        vim.api.nvim_create_autocmd("BufLeave", {
          group = group,
          buffer = file,
          once = true,
          callback = function()
            vim.api.nvim_set_current_win(first)
          end,
        })
      ]],
        {}
      )

      assert.equal("terminal", result.plain.first_shows, "a plain swap is redirected, or the test proves nothing")
      assert.equal("file", result.helper.first_shows)
      assert.equal("terminal", result.helper.split_shows)
      assert.same(result.plain.log, result.helper.log)
    end)
  end)

  describe("utils.win_set_buf_in_split in a real Neovim", function()
    ---Runs the helper for a split that shows a file, with the terminal buffer to show, after `arrange` made windows and
    ---autocmds. `arrange` gets the file buffer, the terminal buffer and the split, and returns the windows to report.
    local function run(arrange)
      start_child()
      return call(
        [[
        local arrange = load(...)
        local utils = require("claudecode.utils")
        local file = vim.api.nvim_create_buf(true, false)
        local terminal = vim.api.nvim_create_buf(true, false)
        vim.cmd("tabnew")
        vim.api.nvim_win_set_buf(0, file)
        vim.cmd("vsplit")
        local split = vim.api.nvim_get_current_win()
        local reported = arrange(file, terminal, split)
        utils.win_set_buf_in_split(split, terminal)
        local function classify(win)
          if not vim.api.nvim_win_is_valid(win) then
            return "closed"
          end
          local buf = vim.api.nvim_win_get_buf(win)
          return buf == terminal and "terminal" or (buf == file and "file" or "other")
        end
        local result = { split = classify(split), current_is_split = vim.api.nvim_get_current_win() == split }
        for name, win in pairs(reported) do
          result[name] = classify(win)
        end
        return result
      ]],
        arrange
      )
    end

    it("shows the buffer in the split when an autocmd entered a window that already showed the buffer", function()
      local result = run([[
        local file, terminal = ...
        local current = vim.api.nvim_get_current_win()
        vim.cmd("tabnew")
        vim.api.nvim_win_set_buf(0, terminal)
        local other_tab = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(current)
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = file,
          once = true,
          callback = function()
            vim.api.nvim_set_current_win(other_tab)
          end,
        })
        return { other_tab = other_tab }
      ]])

      assert.equal("terminal", result.split)
      assert.equal("terminal", result.other_tab)
      assert.is_true(result.current_is_split)
    end)

    it("shows the buffer in the split when an autocmd entered a window that it created", function()
      local result = run([[
        local file = ...
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = file,
          once = true,
          callback = function()
            vim.cmd("new")
          end,
        })
        return {}
      ]])

      assert.equal("terminal", result.split)
      assert.is_true(result.current_is_split)
    end)

    it("shows the buffer in the split when an autocmd closed the window that it entered", function()
      local result = run([[
        local file = ...
        local first = vim.api.nvim_get_current_win()
        vim.cmd("wincmd p")
        local other = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(first)
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = file,
          once = true,
          callback = function()
            vim.api.nvim_set_current_win(other)
            vim.api.nvim_win_close(other, true)
          end,
        })
        return {}
      ]])

      assert.equal("terminal", result.split)
    end)

    it("shows nothing, and raises no error, when an autocmd closed the split", function()
      local result = run([[
        local file, _, split = ...
        local first
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if win ~= split then
            first = win
          end
        end
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = file,
          once = true,
          callback = function()
            vim.api.nvim_set_current_win(first)
            vim.api.nvim_win_close(split, true)
          end,
        })
        return { first = first }
      ]])

      assert.equal("closed", result.split)
      assert.equal("file", result.first)
    end)

    it("leaves a window alone that a BufWinEnter autocmd of the terminal buffer showed it in on purpose", function()
      local result = run([[
        local file, terminal = ...
        vim.cmd("vsplit")
        local mirror = vim.api.nvim_get_current_win()
        vim.cmd("wincmd p")
        vim.api.nvim_win_set_buf(mirror, file)
        vim.api.nvim_create_autocmd("BufWinEnter", {
          buffer = terminal,
          once = true,
          callback = function()
            vim.api.nvim_win_set_buf(mirror, terminal)
          end,
        })
        return { mirror = mirror }
      ]])

      assert.equal("terminal", result.split)
      assert.equal("terminal", result.mirror)
    end)
  end)

  describe("a BufLeave autocmd of the user's file", function()
    ---A file of the user's with an edit, and an autosave autocmd that runs when the cursor leaves it.
    local function arm_autosave()
      call([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "user edit" })
        _G.autosaves = 0
        vim.api.nvim_create_autocmd("BufLeave", {
          pattern = "*.txt",
          callback = function()
            _G.autosaves = _G.autosaves + 1
            vim.cmd("silent! update")
          end,
        })
      ]])
    end

    local function expect_saved()
      local state = call([[return { disk = vim.fn.readfile(_G.dir .. "/a.txt"), autosaves = _G.autosaves }]])
      assert.same({ "user edit" }, state.disk, "the autosave must write the edit before the cursor leaves the file")
      assert.equal(1, state.autosaves)
    end

    it("still saves the file when a new terminal is opened with focus", function()
      start_child()
      arm_autosave()

      call([[require("claudecode.terminal").open()]])

      expect_saved()
    end)

    it("still saves the file when a hidden terminal is shown with focus", function()
      start_child()
      hide_terminal()
      arm_autosave()

      call([[require("claudecode.terminal").open()]])

      expect_saved()
    end)
  end)

  describe("a BufWinEnter autocmd for terminal buffers", function()
    it("runs in the split, with the terminal buffer current, when a hidden terminal is shown", function()
      start_child()
      hide_terminal()
      call([[
        _G.seen = {}
        vim.api.nvim_create_autocmd("BufWinEnter", {
          pattern = "term://*",
          callback = function(event)
            table.insert(_G.seen, {
              buf_is_terminal = event.buf == require("claudecode.terminal").get_active_terminal_bufnr(),
              current_is_terminal = vim.api.nvim_get_current_buf() == event.buf,
              window_is_terminal_window = vim.api.nvim_get_current_win()
                == vim.fn.win_findbuf(event.buf)[1],
            })
          end,
        })
      ]])

      call([[require("claudecode.terminal").open()]])

      local seen = call([[return _G.seen]])
      assert.equal(1, #seen)
      assert.same({ buf_is_terminal = true, current_is_terminal = true, window_is_terminal_window = true }, seen[1])
    end)
  end)

  describe("an OptionSet autocmd of the user's for 'eventignore'", function()
    ---A handler that fails, or that enters another window, would leave the swap in a state of its own: the provider
    ---gives it no change of 'eventignore' to react to, so the test counts the runs.
    local function arm_option_set_autocmd()
      call([[
        _G.option_sets = 0
        vim.api.nvim_create_autocmd("OptionSet", {
          pattern = "eventignore",
          callback = function()
            _G.option_sets = _G.option_sets + 1
          end,
        })
      ]])
    end

    local function expect_no_option_write()
      local state = call([[return { runs = _G.option_sets, eventignore = vim.o.eventignore }]])
      assert.equal(0, state.runs, "the provider must not write 'eventignore'")
      assert.equal("", state.eventignore)
      assert.equal(1, #terminal_windows())
    end

    it("never runs while a new terminal is shown in its split", function()
      start_child()
      arm_option_set_autocmd()

      call([[require("claudecode.terminal").ensure_visible()]])

      expect_no_option_write()
    end)

    it("never runs while a hidden terminal is shown in its split", function()
      start_child()
      hide_terminal()
      arm_option_set_autocmd()

      call([[require("claudecode.terminal").ensure_visible()]])

      expect_no_option_write()
    end)

    it("never runs while a BufEnter autocmd swapped another buffer into the new terminal's split", function()
      start_child()
      open_user_window()
      arm_scratch_swap(false)
      arm_option_set_autocmd()

      call([[require("claudecode.terminal").ensure_visible()]])

      expect_no_option_write()
    end)
  end)

  describe("a BufLeave autocmd that also changes the buffer of the window it enters", function()
    ---A session plugin of the user's: the cursor leaves the file, an autocmd enters the original window, and a WinEnter
    ---autocmd shows another buffer in it. The file then shows in the split only. `hidden` is the global option.
    local function arm_session_switch(hidden)
      call(
        [[
        local hidden = ...
        vim.o.hidden = true
        _G.original = vim.api.nvim_get_current_win()
        _G.file = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(_G.file, 0, -1, false, { "unsaved user edit" })
        _G.other = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_lines(_G.other, 0, -1, false, { "other session buffer" })
        local terminal = require("claudecode.terminal")
        terminal.open()
        for _, win in ipairs(vim.fn.win_findbuf(terminal.get_active_terminal_bufnr())) do
          vim.api.nvim_win_close(win, false)
        end
        _G.job = vim.b[terminal.get_active_terminal_bufnr()].terminal_job_id
        vim.o.hidden = hidden
        local switching = false
        vim.api.nvim_create_autocmd("WinEnter", {
          callback = function()
            if switching and vim.api.nvim_get_current_win() == _G.original then
              vim.api.nvim_win_set_buf(_G.original, _G.other)
            end
          end,
        })
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = _G.file,
          once = true,
          nested = true,
          callback = function()
            switching = true
            vim.api.nvim_set_current_win(_G.original)
            switching = false
          end,
        })
      ]],
        hidden
      )
    end

    local function state()
      return call([[
        local terminal = require("claudecode.terminal")
        local buf = terminal.get_active_terminal_bufnr()
        return {
          terminal_windows = #vim.fn.win_findbuf(buf),
          job_running = vim.fn.jobwait({ _G.job }, 10)[1] == -1,
          file_loaded = vim.api.nvim_buf_is_loaded(_G.file),
          file_lines = vim.api.nvim_buf_get_lines(_G.file, 0, -1, false),
          original_shows_other = vim.api.nvim_win_get_buf(_G.original) == _G.other,
        }
      ]])
    end

    it("shows the hidden terminal in its split, and keeps the unsaved file loaded, when 'hidden' is on", function()
      start_child()
      arm_session_switch(true)

      call([[require("claudecode.terminal").open()]])

      local result = state()
      assert.equal(1, result.terminal_windows)
      assert.is_true(result.job_running)
      assert.is_true(result.file_loaded)
      assert.same({ "unsaved user edit" }, result.file_lines)
      assert.is_true(result.original_shows_other)
    end)

    -- Neovim checks that the swap can leave a modified buffer before it runs BufLeave autocmds, and the autocmd here
    -- takes away the other window that made it pass. Showing the terminal in the split would hide the unsaved file
    -- that 'nohidden' keeps from being hidden, so the open fails like any other swap of such a buffer does. A plain
    -- swap showed the terminal in the original window instead, which is the redirect this placement prevents.
    it("raises E37 for the hidden terminal, and loses nothing, when 'hidden' is off", function()
      start_child()
      arm_session_switch(false)

      local ok, err = pcall(call, [[require("claudecode.terminal").open()]])

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("E37", 1, true))
      local result = state()
      assert.equal(0, result.terminal_windows)
      assert.is_true(result.job_running)
      assert.is_true(result.file_loaded)
      assert.same({ "unsaved user edit" }, result.file_lines)

      -- The autocmd ran once, so the next call shows the terminal beside the other windows.
      call([[require("claudecode.terminal").open()]])
      assert.equal(1, state().terminal_windows)
    end)
  end)
end)

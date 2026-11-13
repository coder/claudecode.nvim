if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the terminal's placement in its own split", function()
    pending("needs a real Neovim")
  end)
  return
end

-- `nvim_win_set_buf` runs the BufLeave autocmds of the buffer it replaces inside the call. When one of them enters
-- another window, Neovim loads the new buffer into that window, even though the call names another one. The providers
-- put the terminal into the split they made with `utils.win_set_buf_in_split`. It fires `BufLeave` for the old buffer
-- itself, in the split, while the buffer still shows there. An autocmd that enters another window only moves the
-- cursor, and the helper puts it back in the split. Then it makes the swap with `BufLeave` in 'eventignore', so Neovim
-- fires the other events of the swap itself, after the `BufLeave` autocmds are done: `BufWinLeave`, `BufHidden` and
-- `BufUnload` of a buffer that lost its last window, also when a `BufLeave` autocmd closed the other window of it.
-- The events and their order are a plain swap's. What a plain swap does in shapes with no redirect is pinned by
-- terminal_placement_contract_spec.lua, which passes on a tree with no helper.
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

  describe("the events of the placement", function()
    ---Runs `swap` for a split of a file in a tab of its own, once as a plain `nvim_win_set_buf` (`use_helper` false) and
    ---once as the helper, with a logger on the events a swap fires. `prepare` gets the file, the terminal buffer, the
    ---split, the window that the file also shows in and the augroup of the logger, and can add autocmds and set options.
    ---Each line of a log has the event, the buffer it is for, the window that is current and the buffer in it.
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
          local function window_name(win)
            return win == split and "split" or (win == first and "first" or "other")
          end
          local group = vim.api.nvim_create_augroup("swap_events_" .. tostring(use_helper), { clear = true })
          prepare(file, terminal, split, first, group, opts.close_first)
          local log = {}
          vim.api.nvim_create_autocmd(
            { "BufLeave", "BufEnter", "BufWinEnter", "BufWinLeave", "BufHidden", "WinEnter", "WinLeave" },
            {
              group = group,
              callback = function(event)
                table.insert(
                  log,
                  event.event .. "@" .. role(event.buf)
                    .. " in " .. window_name(vim.api.nvim_get_current_win())
                    .. " showing " .. role(vim.api.nvim_get_current_buf())
                )
              end,
            }
          )
          local ok, err
          if use_helper then
            ok, err = pcall(utils.win_set_buf_in_split, split, terminal, { ignore_bufenter = opts.ignore_bufenter })
          else
            local saved = vim.o.eventignore
            if opts.ignore_bufenter then
              vim.o.eventignore = "BufEnter"
            end
            ok, err = pcall(vim.api.nvim_win_set_buf, split, terminal)
            vim.o.eventignore = saved
          end
          vim.api.nvim_clear_autocmds({ group = group })
          return {
            ok = ok,
            err = ok and "" or (tostring(err):match("E%d+") or (tostring(err):gsub("^.-:%d+: ", ""):gsub("%d+", "N"))),
            eventignore = vim.o.eventignore,
            log = log,
            tabstops = {
              file = vim.api.nvim_buf_is_valid(file) and vim.bo[file].tabstop or -1,
              terminal = vim.api.nvim_buf_is_valid(terminal) and vim.bo[terminal].tabstop or -1,
            },
            split_shows = vim.api.nvim_win_is_valid(split) and role(vim.api.nvim_win_get_buf(split)) or "closed",
            first_shows = vim.api.nvim_win_is_valid(first) and role(vim.api.nvim_win_get_buf(first)) or "closed",
            current = window_name(vim.api.nvim_get_current_win()),
          }
        end
        return { plain = run(false), helper = run(true) }
      ]],
        prepare,
        opts or {}
      )
    end

    local function plain_events()
      return {
        "BufLeave@file in split showing file",
        "BufEnter@terminal in split showing terminal",
        "BufWinEnter@terminal in split showing terminal",
      }
    end

    it("are the plain swap's, in the same order, when the buffer also shows elsewhere", function()
      local result = logs("", {})

      assert.same(plain_events(), result.plain.log)
      assert.same(result.plain.log, result.helper.log)
      assert.equal("terminal", result.helper.split_shows)
      assert.equal("file", result.helper.first_shows)
      assert.equal("split", result.helper.current)
    end)

    it("leave BufEnter out when the call ignores it, as a swap that ignores it does", function()
      local result = logs("", { ignore_bufenter = true })

      assert.same({
        "BufLeave@file in split showing file",
        "BufWinEnter@terminal in split showing terminal",
      }, result.plain.log)
      assert.same(result.plain.log, result.helper.log)
    end)

    it("run the BufEnter autocmds of the user's for the terminal buffer once, in the split", function()
      local result = logs(
        [[
        local _, terminal, _, _, group = ...
        vim.api.nvim_create_autocmd("BufEnter", {
          group = group,
          buffer = terminal,
          callback = function() end,
        })
      ]],
        {}
      )

      assert.same(plain_events(), result.helper.log)
    end)

    it("run an autosave autocmd once, in the split that shows the file, before the file is left", function()
      local result = logs(
        [[
        local file, _, _, _, group = ...
        vim.api.nvim_buf_set_lines(file, 0, -1, false, { "user edit" })
        vim.api.nvim_buf_set_name(file, _G.dir .. "/saved-" .. file .. ".txt")
        _G.autosave_runs = _G.autosave_runs or 0
        vim.api.nvim_create_autocmd("BufLeave", {
          group = group,
          buffer = file,
          callback = function()
            _G.autosave_runs = _G.autosave_runs + 1
            vim.cmd("silent! update")
          end,
        })
      ]],
        {}
      )

      assert.same(plain_events(), result.helper.log)
      -- One run for the plain swap, one for the helper.
      assert.equal(2, call([[return _G.autosave_runs]]))
    end)

    for _, case in ipairs({
      { name = "shows in another window", close_first = false },
      { name = "shows in no other window", close_first = true },
    }) do
      it("read no modeline of either buffer when the buffer they replace " .. case.name, function()
        local result = logs(
          [[
          local file, terminal, _, first, _, close_first = ...
          vim.o.modeline = true
          vim.bo[file].bufhidden = "hide"
          -- Set after the buffers were loaded, so only a call that processes modelines reads them.
          vim.api.nvim_buf_set_lines(file, 0, -1, false, { "vim: ts=5" })
          vim.api.nvim_buf_set_lines(terminal, 0, -1, false, { "vim: ts=6" })
          if close_first then
            vim.api.nvim_win_close(first, true)
          end
        ]],
          { close_first = case.close_first }
        )

        assert.same({ file = 8, terminal = 8 }, result.plain.tabstops)
        assert.same(result.plain.tabstops, result.helper.tabstops)
      end)
    end

    describe(
      "are exactly the plain swap's, with the same current window and buffer, when no other window shows the buffer",
      function()
        local function expect_plain(prepare)
          local result = logs(prepare, { close_first = true })

          assert.equal("terminal", result.plain.split_shows)
          assert.is_true(#result.plain.log > 0, "the swap must fire events, or the test proves nothing")
          assert.same(result.plain.log, result.helper.log)
          assert.same(result.plain.current, result.helper.current)
        end

        it("and the buffer stays loaded", function()
          expect_plain([[
          local file, _, _, first = ...
          vim.bo[file].bufhidden = "hide"
          vim.api.nvim_win_close(first, true)
        ]])
        end)

        it("and 'hidden' is on", function()
          expect_plain([[
          local _, _, _, first = ...
          vim.o.hidden = true
          vim.api.nvim_win_close(first, true)
        ]])
        end)

        it("and the swap unloads it", function()
          expect_plain([[
          local _, _, _, first = ...
          vim.o.hidden = false
          vim.api.nvim_win_close(first, true)
        ]])
        end)
      end
    )

    for _, nested in ipairs({ false, true }) do
      -- Neovim fires none of its events for what an autocmd does, unless the autocmd is nested. `nvim_exec_autocmds`
      -- fires them anyway, so the helper fires BufWinEnter only when Neovim ran its own enter events.
      it(
        "fire BufWinEnter " .. (nested and "inside" or "not inside") .. " a nested autocmd, as a plain swap does",
        function()
          start_child()
          local result = call(
            [[
          local nested = ...
          local utils = require("claudecode.utils")
          local function run(use_helper)
            vim.cmd("tabnew")
            local file = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_win_set_buf(0, file)
            vim.cmd("vsplit")
            local split = vim.api.nvim_get_current_win()
            local terminal = vim.api.nvim_create_buf(true, false)
            local group = vim.api.nvim_create_augroup("nested_events_" .. tostring(use_helper), { clear = true })
            local seen = {}
            vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "BufLeave", "WinEnter" }, {
              group = group,
              callback = function(event)
                table.insert(seen, event.event)
              end,
            })
            vim.api.nvim_create_autocmd("User", {
              group = group,
              pattern = "PlacementRun",
              nested = nested,
              callback = function()
                if use_helper then
                  utils.win_set_buf_in_split(split, terminal)
                else
                  vim.api.nvim_win_set_buf(split, terminal)
                end
              end,
            })
            vim.api.nvim_exec_autocmds("User", { pattern = "PlacementRun", group = group })
            vim.api.nvim_clear_autocmds({ group = group })
            local count = 0
            for _, name in ipairs(seen) do
              count = name == "BufWinEnter" and count + 1 or count
            end
            return { seen = seen, buf_win_enter = count, split_shows_terminal = vim.api.nvim_win_get_buf(split) == terminal }
          end
          return { plain = run(false), helper = run(true) }
        ]],
            nested
          )

          assert.is_true(result.helper.split_shows_terminal)
          assert.equal(nested and 1 or 0, result.plain.buf_win_enter, "a plain swap sets the reference")
          assert.equal(result.plain.buf_win_enter, result.helper.buf_win_enter)
          if not nested then
            assert.same({}, result.helper.seen)
          end
        end
      )
    end

    it("are the same when a BufLeave autocmd enters another window, and the terminal lands in the split", function()
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
      -- The autocmd ran in the split and entered the other window. The helper put the cursor back with no event, so the
      -- terminal's BufEnter and BufWinEnter run in the split.
      assert.same({
        "BufLeave@file in first showing file",
        "BufEnter@terminal in split showing terminal",
        "BufWinEnter@terminal in split showing terminal",
      }, result.helper.log)
    end)

    -- A BufLeave autocmd that changes the windows or the buffers, and does not enter another window: a plain swap and
    -- the helper must end the same, with the same events.
    local quiet_shapes = {
      { name = "closes the other window of the buffer", handler = "vim.api.nvim_win_close(first, false)" },
      { name = "wipes the buffer that is to be shown", handler = 'vim.cmd("bwipeout! " .. terminal)' },
    }
    for _, shape in ipairs(quiet_shapes) do
      for _, nested in ipairs({ false, true }) do
        it(
          "end as a plain swap does when a BufLeave autocmd " .. shape.name .. (nested and ", nested" or ", not nested"),
          function()
            local result = logs(
              string.format(
                [[
              local file, terminal, split, first, group = ...
              vim.api.nvim_create_autocmd("BufLeave", {
                group = group,
                buffer = file,
                once = true,
                nested = %s,
                callback = function()
                  %s
                end,
              })
            ]],
                tostring(nested),
                shape.handler
              ),
              {}
            )

            assert.equal(result.plain.ok, result.helper.ok, result.plain.err .. " / " .. result.helper.err)
            assert.equal(result.plain.err, result.helper.err)
            assert.same(result.plain.log, result.helper.log)
            assert.equal(result.plain.split_shows, result.helper.split_shows)
            assert.equal(result.plain.first_shows, result.helper.first_shows)
            assert.equal(result.plain.current, result.helper.current)
          end
        )
      end
    end

    -- A plain swap fires BufWinLeave and BufHidden for the file here, which is still shown in the first window, and none
    -- for the empty buffer that it replaces. Neovim fires them for a buffer that left its last window.
    it("fires BufWinLeave and BufHidden for the buffer a BufLeave autocmd put into the split, and then left", function()
      local result = logs(
        [[
        local file, _, _, _, group = ...
        vim.api.nvim_create_autocmd("BufLeave", {
          group = group,
          buffer = file,
          once = true,
          callback = function()
            vim.cmd("enew")
          end,
        })
      ]],
        {}
      )

      assert.is_true(result.helper.ok, result.helper.err)
      assert.same({
        "BufLeave@file in split showing other",
        "BufWinLeave@other in split showing other",
        "BufHidden@other in split showing other",
        "BufEnter@terminal in split showing terminal",
        "BufWinEnter@terminal in split showing terminal",
      }, result.helper.log)
      assert.equal("terminal", result.helper.split_shows)
      assert.equal("file", result.helper.first_shows)
    end)

    it("runs the BufLeave autocmds of the user's with a plain swap's arguments, in the split", function()
      local result = logs(
        [[
        local file, _, split, _, group = ...
        _G.seen = _G.seen or {}
        vim.api.nvim_create_autocmd("BufLeave", {
          group = group,
          buffer = file,
          callback = function(event)
            table.insert(_G.seen, {
              buf_is_file = event.buf == file,
              file_is_name = event.file == vim.api.nvim_buf_get_name(file),
              match_is_name = event.match == vim.api.nvim_buf_get_name(file),
              abuf_is_file = tonumber(vim.fn.expand("<abuf>")) == file,
              in_split = vim.api.nvim_get_current_win() == split,
              mode = vim.api.nvim_get_mode().mode,
              eventignore = vim.o.eventignore,
            })
          end,
        })
      ]],
        {}
      )

      local seen = call([[return _G.seen]])
      assert.equal(2, #seen, "one run for the plain swap, one for the helper")
      assert.same(seen[1], seen[2])
      assert.is_true(seen[1].buf_is_file)
      assert.is_true(seen[1].in_split)
      assert.equal("", seen[1].eventignore)
      assert.is_true(result.helper.ok)
    end)

    it("leaves 'eventignore' as the caller set it, entries that unignore an event included", function()
      local result = logs(
        [[
        -- Neovim 0.8 takes no entry that unignores an event.
        if not pcall(function()
          vim.o.eventignore = "CursorHold,-BufLeave,-OptionSet"
        end) then
          vim.o.eventignore = "CursorHold"
        end
        _G.caller_eventignore = vim.o.eventignore
      ]],
        { ignore_bufenter = true }
      )

      assert.is_true(result.helper.ok, result.helper.err)
      assert.equal(call([[return _G.caller_eventignore]]), result.helper.eventignore)
      assert.same(result.plain.log, result.helper.log)
    end)

    it("makes a plain swap, and fails as it does, in a window with 'winfixbuf'", function()
      if vim.fn.exists("&winfixbuf") ~= 1 then
        return pending("needs Neovim 0.10")
      end
      local result = logs(
        [[
        local _, _, split = ...
        vim.wo[split].winfixbuf = true
        _G.leaves = 0
        vim.api.nvim_create_autocmd("BufLeave", {
          callback = function()
            _G.leaves = _G.leaves + 1
          end,
        })
      ]],
        {}
      )

      assert.is_false(result.plain.ok)
      assert.is_false(result.helper.ok)
      assert.equal(result.plain.err, result.helper.err)
      assert.equal("file", result.helper.split_shows)
      assert.equal(0, call([[return _G.leaves]]), "a swap that Neovim refuses fires no BufLeave")
    end)

    -- Inside an autocmd Neovim fires no event of its own for a swap, unless the autocmd is nested. The helper makes the
    -- plain swap there, with the redirect of a BufLeave autocmd that is nested and enters another window, and fires
    -- BufLeave once, as the plain swap does.
    it("makes a plain swap inside a nested autocmd, and fires BufLeave once", function()
      start_child()
      local result = call([[
        local utils = require("claudecode.utils")
        local function run(use_helper)
          vim.cmd("tabnew")
          local file = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_win_set_buf(0, file)
          local first = vim.api.nvim_get_current_win()
          vim.cmd("vsplit")
          local split = vim.api.nvim_get_current_win()
          local terminal = vim.api.nvim_create_buf(true, false)
          local group = vim.api.nvim_create_augroup("inside_autocmd_" .. tostring(use_helper), { clear = true })
          local leaves = 0
          vim.api.nvim_create_autocmd("BufLeave", {
            group = group,
            buffer = file,
            nested = true,
            callback = function()
              leaves = leaves + 1
              vim.api.nvim_set_current_win(first)
            end,
          })
          vim.api.nvim_create_autocmd("User", {
            group = group,
            pattern = "PlacementRun",
            nested = true,
            callback = function()
              if use_helper then
                utils.win_set_buf_in_split(split, terminal)
              else
                vim.api.nvim_win_set_buf(split, terminal)
              end
            end,
          })
          vim.api.nvim_exec_autocmds("User", { pattern = "PlacementRun", group = group })
          vim.api.nvim_clear_autocmds({ group = group })
          return {
            leaves = leaves,
            first_shows_terminal = vim.api.nvim_win_get_buf(first) == terminal,
            split_shows_terminal = vim.api.nvim_win_get_buf(split) == terminal,
          }
        end
        return { plain = run(false), helper = run(true) }
      ]])

      assert.equal(1, result.plain.leaves)
      assert.same(result.plain, result.helper)
    end)

    it("makes a plain swap, and fails as it does, for an unsaved file that no other window shows", function()
      local result = logs(
        [[
        local file, _, _, first = ...
        vim.o.hidden = false
        vim.api.nvim_buf_set_lines(file, 0, -1, false, { "unsaved" })
        vim.api.nvim_win_close(first, true)
        _G.leaves = 0
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = file,
          callback = function()
            _G.leaves = _G.leaves + 1
          end,
        })
      ]],
        { close_first = true }
      )

      assert.is_false(result.plain.ok)
      assert.is_false(result.helper.ok)
      assert.equal(result.plain.err, result.helper.err, "the error of the plain swap")
      assert.equal(0, call([[return _G.leaves]]), "a swap that Neovim refuses fires no BufLeave")
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
        local placed = utils.win_set_buf_in_split(split, terminal)
        local function classify(win)
          if not vim.api.nvim_win_is_valid(win) then
            return "closed"
          end
          local buf = vim.api.nvim_win_get_buf(win)
          return buf == terminal and "terminal" or (buf == file and "file" or "other")
        end
        local result = {
          split = classify(split),
          current_is_split = vim.api.nvim_get_current_win() == split,
          placed = placed,
        }
        for name, win in pairs(reported) do
          result[name] = classify(win)
        end
        return result
      ]],
        arrange
      )
    end

    ---The state of the buffer `_G.other` that an autocmd of BufLeave showed in the split: the helper must not lose its text.
    local function other_buffer()
      return call([[
        local buf = _G.other
        local loaded = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
        return { valid = vim.api.nvim_buf_is_valid(buf), loaded = loaded, lines = loaded and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {} }
      ]])
    end

    -- A BufLeave autocmd shows another buffer in the split. `:buffer!` skips the E37 check of a plain swap, and it unloads
    -- or wipes a changed buffer with these values of 'bufhidden'. A plain swap keeps the text.
    for _, bufhidden in ipairs({ "unload", "delete", "wipe" }) do
      it(
        "keeps the text of a new buffer that an autocmd showed in the split, with 'bufhidden' " .. bufhidden,
        function()
          local result = run(string.format(
            [[
          local file, terminal, split = ...
          _G.other = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_buf_set_lines(_G.other, 0, -1, false, { "unsaved X text" })
          vim.bo[_G.other].bufhidden = %q
          vim.api.nvim_create_autocmd("BufLeave", {
            buffer = file,
            once = true,
            callback = function()
              vim.api.nvim_win_set_buf(split, _G.other)
            end,
          })
          return {}
        ]],
            bufhidden
          ))

          local other = other_buffer()
          assert.same({ valid = true, loaded = true, lines = { "unsaved X text" } }, other)
          assert.is_false(result.placed)
          assert.equal("other", result.split)
        end
      )

      it(
        "keeps the unsaved text of a file that an autocmd moved into the split, with 'bufhidden' " .. bufhidden,
        function()
          -- The file shows in a window W, and the autocmd shows it in the split and closes W.
          local result = run(string.format(
            [[
          local file, terminal, split = ...
          vim.cmd("belowright split")
          local window = vim.api.nvim_get_current_win()
          _G.other = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_win_set_buf(window, _G.other)
          vim.api.nvim_buf_set_lines(_G.other, 0, -1, false, { "user typed this, unsaved" })
          vim.bo[_G.other].bufhidden = %q
          vim.api.nvim_set_current_win(split)
          vim.api.nvim_create_autocmd("BufLeave", {
            buffer = file,
            once = true,
            callback = function()
              vim.api.nvim_win_set_buf(split, _G.other)
              vim.api.nvim_win_close(window, true)
            end,
          })
          return {}
        ]],
            bufhidden
          ))

          local other = other_buffer()
          assert.same({ valid = true, loaded = true, lines = { "user typed this, unsaved" } }, other)
          assert.is_false(result.placed)
          assert.equal("other", result.split)
        end
      )
    end

    for _, bufhidden in ipairs({ "", "hide" }) do
      it(
        "shows the buffer, and keeps the text of the other buffer, when it can be hidden, with 'bufhidden' '"
          .. bufhidden
          .. "'",
        function()
          local result = run(string.format(
            [[
          local file, terminal, split = ...
          _G.other = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_buf_set_lines(_G.other, 0, -1, false, { "unsaved X text" })
          vim.bo[_G.other].bufhidden = %q
          vim.api.nvim_create_autocmd("BufLeave", {
            buffer = file,
            once = true,
            callback = function()
              vim.api.nvim_win_set_buf(split, _G.other)
            end,
          })
          return {}
        ]],
            bufhidden
          ))

          assert.same({ valid = true, loaded = true, lines = { "unsaved X text" } }, other_buffer())
          assert.is_true(result.placed)
          assert.equal("terminal", result.split)
        end
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

  describe("a BufLeave autocmd of the user's file that closes the split it runs in", function()
    ---The autocmd runs in the split, which the provider just made, and closes it. A plain swap then loads the terminal
    ---into the window that the cursor ends in, the user's. The helper shows nothing, and the terminal stays hidden.
    local function arm_split_close()
      call([[
        _G.original = vim.api.nvim_get_current_win()
        _G.file = vim.api.nvim_get_current_buf()
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = _G.file,
          once = true,
          callback = function()
            vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
          end,
        })
      ]])
    end

    local function split_close_state()
      return call([[
        local terminal = require("claudecode.terminal")
        local buf = terminal.get_active_terminal_bufnr()
        return {
          terminal_windows = buf and vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) or 0,
          job_running = buf ~= nil and vim.fn.jobwait({ vim.b[buf].terminal_job_id }, 10)[1] == -1,
          original_shows_file = vim.api.nvim_win_is_valid(_G.original)
            and vim.api.nvim_win_get_buf(_G.original) == _G.file,
          windows = #vim.api.nvim_tabpage_list_wins(0),
        }
      ]])
    end

    it("leaves a hidden terminal hidden, and the user's window alone, with no error", function()
      start_child()
      hide_terminal()
      arm_split_close()

      local ok = pcall(vim.rpcrequest, chan, "nvim_exec_lua", [[vim.cmd("ClaudeCodeOpen")]], {})

      local state = split_close_state()
      assert.is_true(ok, "the command must not fail")
      assert.equal(0, state.terminal_windows)
      assert.is_true(state.job_running)
      assert.is_true(state.original_shows_file, "the user's window must keep the file")
      assert.equal(1, state.windows)
    end)

    ---A third window W, and a BufLeave autocmd of the user's file (once). The autocmd (`kind`) enters W and closes the
    ---split (nil), or closes the user's window first and then does that ("both"), or wipes the hidden terminal's buffer
    ---and closes no window ("wipe"), or closes Claude (`:ClaudeCodeClose` as "close_command", `terminal.close()` as
    ---"close_api"), which deletes the buffer and clears the provider's record of it. "winnew_close" and
    ---"winenter_close" arm no BufLeave autocmd: a `WinNew` or `WinEnter` autocmd of the show's own split closes Claude.
    local function arm_split_close_from_third_window(kind)
      call(
        [[
        local kind = ...
        _G.notes = {}
        vim.notify = function(message)
          table.insert(_G.notes, message)
        end
        require("claudecode.logger").setup({ log_level = "info" })
        _G.original = vim.api.nvim_get_current_win()
        _G.file = vim.api.nvim_get_current_buf()
        vim.cmd("belowright split " .. vim.fn.fnameescape(_G.dir .. "/other.txt"))
        _G.third = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(_G.original)
        _G.term_buf = require("claudecode.terminal").get_active_terminal_bufnr()
        if kind == "winnew_close" or kind == "winenter_close" then
          vim.api.nvim_create_autocmd(kind == "winnew_close" and "WinNew" or "WinEnter", {
            once = true,
            callback = function()
              require("claudecode.terminal").close()
            end,
          })
          return
        end
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = _G.file,
          once = true,
          callback = function()
            if kind == "wipe" then
              vim.cmd("bwipeout! " .. _G.term_buf)
              return
            end
            if kind == "close_command" then
              vim.cmd("ClaudeCodeClose")
              return
            end
            if kind == "close_api" then
              require("claudecode.terminal").close()
              return
            end
            local split = vim.api.nvim_get_current_win()
            if kind == "both" then
              vim.api.nvim_win_close(_G.original, true)
            end
            vim.api.nvim_set_current_win(_G.third)
            vim.api.nvim_win_close(split, true)
          end,
        })
      ]],
        kind
      )
    end

    local function third_window_state()
      return call([[
        vim.wait(300)
        return {
          cursor = vim.api.nvim_get_current_win() == _G.original and "original"
            or (vim.api.nvim_get_current_win() == _G.third and "third" or "other"),
          original_valid = vim.api.nvim_win_is_valid(_G.original),
          notes = _G.notes,
        }
      ]])
    end

    it("puts the cursor back in the user's window, and logs nothing, without focus", function()
      start_child()
      hide_terminal()
      arm_split_close_from_third_window()

      local ok = pcall(vim.rpcrequest, chan, "nvim_exec_lua", [[require("claudecode.terminal").ensure_visible()]], {})

      local state = third_window_state()
      assert.is_true(ok, "the call must not fail")
      assert.equal("original", state.cursor, "a show without focus leaves the cursor where the user was")
      assert.same({}, state.notes)
      assert.equal(0, split_close_state().terminal_windows)
    end)

    it("logs nothing, and leaves the cursor where the autocmd put it, with focus", function()
      start_child()
      hide_terminal()
      arm_split_close_from_third_window()

      local ok = pcall(vim.rpcrequest, chan, "nvim_exec_lua", [[vim.cmd("ClaudeCodeOpen")]], {})

      local state = third_window_state()
      assert.is_true(ok, "the command must not fail")
      assert.equal("third", state.cursor)
      assert.same({}, state.notes)
      assert.equal(0, split_close_state().terminal_windows)
    end)

    it("does not enter the user's window, and logs nothing, when the autocmd closed it too", function()
      -- The autocmd closes the window that the show started in, then enters W and closes the split.
      start_child()
      hide_terminal()
      arm_split_close_from_third_window("both")

      local ok, err =
        pcall(vim.rpcrequest, chan, "nvim_exec_lua", [[require("claudecode.terminal").ensure_visible()]], {})

      local state = third_window_state()
      assert.is_true(ok, "the call must not fail: " .. tostring(err))
      assert.is_false(state.original_valid)
      assert.equal("third", state.cursor)
      assert.same({}, state.notes)
      assert.equal(0, split_close_state().terminal_windows)
    end)

    for _, command in ipairs({ "ClaudeCode", "ClaudeCodeFocus" }) do
      it("logs nothing, and raises no error, for :" .. command .. " on a hidden terminal", function()
        start_child()
        hide_terminal()
        arm_split_close_from_third_window()

        local ok = pcall(vim.rpcrequest, chan, "nvim_exec_lua", [[vim.cmd(...)]], { command })

        local state = third_window_state()
        assert.is_true(ok, "the command must not fail")
        assert.same({}, state.notes)
        assert.equal(0, split_close_state().terminal_windows)
      end)
    end

    for _, command in ipairs({ "ClaudeCodeOpen", "ClaudeCode", "ClaudeCodeFocus" }) do
      it("says nothing about a closed window when the autocmd wipes the terminal's buffer, for :" .. command, function()
        -- No window closed, and main says nothing either.
        start_child()
        hide_terminal()
        arm_split_close_from_third_window("wipe")

        local ok = pcall(vim.rpcrequest, chan, "nvim_exec_lua", [[vim.cmd(...)]], { command })

        local state = third_window_state()
        assert.is_true(ok, "the command must not fail")
        assert.same({}, state.notes)
      end)
    end

    for _, closer in ipairs({ "close_command", "close_api" }) do
      for _, entry in ipairs({ "ClaudeCodeOpen", "ClaudeCode", "ClaudeCodeFocus", "ensure_visible" }) do
        it(
          "raises no error and logs nothing when the autocmd closes Claude (" .. closer .. "), for " .. entry,
          function()
            -- Closing Claude deletes the buffer and clears the provider's record of it, inside the show.
            start_child()
            hide_terminal()
            arm_split_close_from_third_window(closer)

            local code = entry == "ensure_visible" and [[require("claudecode.terminal").ensure_visible()]]
              or [[vim.cmd(...)]]
            local ok, err = pcall(vim.rpcrequest, chan, "nvim_exec_lua", code, { entry })

            local state = third_window_state()
            assert.is_true(ok, "the call must not fail: " .. tostring(err))
            assert.same({}, state.notes)
            if entry == "ensure_visible" then
              assert.equal("original", state.cursor, "a show without focus leaves the cursor where the user was")
            end
          end
        )
      end
    end

    for _, kind in ipairs({ "winnew_close", "winenter_close" }) do
      for _, entry in ipairs({ "ClaudeCodeOpen", "ClaudeCode", "ClaudeCodeFocus", "ensure_visible" }) do
        it("raises no error when a " .. kind .. " autocmd of the split closes Claude, for " .. entry, function()
          -- The autocmd runs inside the show's `vsplit`, before the swap, and clears the provider's record of the buffer.
          -- `ensure_visible` shows without focus and the commands show with focus.
          start_child()
          hide_terminal()
          arm_split_close_from_third_window(kind)

          local code = entry == "ensure_visible" and [[require("claudecode.terminal").ensure_visible()]]
            or [[vim.cmd(...)]]
          local ok, err = pcall(vim.rpcrequest, chan, "nvim_exec_lua", code, { entry })

          local state = third_window_state()
          assert.is_true(ok, "the call must not fail: " .. tostring(err))
          assert.same({}, state.notes)
        end)
      end
    end

    it("starts a new terminal that stays hidden, and leaves the user's window alone, with no error", function()
      start_child()
      arm_split_close()

      local ok = pcall(vim.rpcrequest, chan, "nvim_exec_lua", [[vim.cmd("ClaudeCode")]], {})

      local state = split_close_state()
      assert.is_true(ok, "the command must not fail")
      assert.equal(0, state.terminal_windows)
      assert.is_true(state.job_running, "the terminal must still start")
      assert.is_true(state.original_shows_file, "the user's window must keep the file")
      assert.equal(1, state.windows)
    end)

    it("starts a new terminal that stays hidden, with no error, when the autocmd wipes the user's file", function()
      -- The wipe closes the split and the window that the split was made from, and only a window of another file is left.
      start_child()
      call([[
        vim.cmd("topleft split " .. vim.fn.fnameescape(_G.dir .. "/other.txt"))
        _G.other_win = vim.api.nvim_get_current_win()
        vim.cmd("wincmd j")
        _G.file = vim.api.nvim_get_current_buf()
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = _G.file,
          once = true,
          callback = function()
            vim.cmd("bwipeout! " .. _G.file)
          end,
        })
      ]])

      local ok, err = pcall(vim.rpcrequest, chan, "nvim_exec_lua", [[vim.cmd("ClaudeCode")]], {})

      local state = call([[
        local terminal = require("claudecode.terminal")
        local buf = terminal.get_active_terminal_bufnr()
        return {
          terminal_windows = buf and vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) or 0,
          job_running = buf ~= nil and vim.fn.jobwait({ vim.b[buf].terminal_job_id }, 10)[1] == -1,
          windows = #vim.api.nvim_tabpage_list_wins(0),
        }
      ]])
      assert.is_true(ok, tostring(err))
      assert.equal(0, state.terminal_windows)
      assert.is_true(state.job_running, "the terminal must still start")
      assert.equal(1, state.windows)
    end)

    ---A BufLeave autocmd of the user's file (once) shows a changed buffer in the split that it runs in, with the given
    ---'bufhidden'. `buffer!` would unload or wipe that buffer with its text, so the helper leaves it in the split.
    local function arm_split_shows_other(bufhidden)
      call(
        [[
        local bufhidden = ...
        _G.notes = {}
        vim.notify = function(message)
          table.insert(_G.notes, message)
        end
        require("claudecode.logger").setup({ log_level = "info" })
        _G.original = vim.api.nvim_get_current_win()
        _G.file = vim.api.nvim_get_current_buf()
        _G.other = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_lines(_G.other, 0, -1, false, { "unsaved X text" })
        vim.bo[_G.other].bufhidden = bufhidden
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = _G.file,
          once = true,
          callback = function()
            vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), _G.other)
          end,
        })
      ]],
        bufhidden
      )
    end

    local function shows_other_state()
      return call([[
        vim.wait(300)
        local buf = require("claudecode.terminal").get_active_terminal_bufnr()
        local loaded = vim.api.nvim_buf_is_valid(_G.other) and vim.api.nvim_buf_is_loaded(_G.other)
        return {
          terminal_windows = buf and vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) or 0,
          job_running = buf ~= nil and vim.fn.jobwait({ vim.b[buf].terminal_job_id }, 10)[1] == -1,
          other_lines = loaded and vim.api.nvim_buf_get_lines(_G.other, 0, -1, false) or {},
          other_windows = vim.api.nvim_buf_is_valid(_G.other) and #vim.fn.win_findbuf(_G.other) or 0,
          cursor_original = vim.api.nvim_get_current_win() == _G.original,
          notes = _G.notes,
        }
      ]])
    end

    for _, bufhidden in ipairs({ "unload", "delete", "wipe" }) do
      it(
        "starts a new terminal that stays hidden, with no error, when the autocmd shows a changed buffer in the split, 'bufhidden' "
          .. bufhidden,
        function()
          -- The helper returns false and keeps the buffer. A plain swap to repair the split after termopen would raise E37.
          start_child()
          arm_split_shows_other(bufhidden)

          local ok, err = pcall(vim.rpcrequest, chan, "nvim_exec_lua", [[vim.cmd("ClaudeCode")]], {})

          local state = shows_other_state()
          assert.is_true(ok, "the command must not fail: " .. tostring(err))
          assert.same({ "unsaved X text" }, state.other_lines)
          assert.equal(1, state.other_windows, "the buffer stays in the split")
          assert.equal(0, state.terminal_windows)
          assert.is_true(state.job_running, "the terminal must still start")
        end
      )

      for _, entry in ipairs({ "ClaudeCodeOpen", "ensure_visible" }) do
        it(
          "shows a hidden terminal nowhere, with no error and no message, when the autocmd shows a changed buffer in the split, 'bufhidden' "
            .. bufhidden
            .. ", for "
            .. entry,
          function()
            start_child()
            hide_terminal()
            arm_split_shows_other(bufhidden)

            local code = entry == "ensure_visible" and [[require("claudecode.terminal").ensure_visible()]]
              or [[vim.cmd(...)]]
            local ok, err = pcall(vim.rpcrequest, chan, "nvim_exec_lua", code, { entry })

            local state = shows_other_state()
            assert.is_true(ok, "the call must not fail: " .. tostring(err))
            assert.same({ "unsaved X text" }, state.other_lines)
            assert.equal(1, state.other_windows, "the buffer stays in the split")
            assert.equal(0, state.terminal_windows)
            assert.is_true(state.job_running, "the terminal must keep running")
            assert.same({}, state.notes)
            if entry == "ensure_visible" then
              assert.is_true(state.cursor_original, "a show without focus leaves the cursor where the user was")
            end
          end
        )
      end
    end

    it("shows the terminal in a split on the next open", function()
      start_child()
      hide_terminal()
      arm_split_close()
      pcall(vim.rpcrequest, chan, "nvim_exec_lua", [[vim.cmd("ClaudeCodeOpen")]], {})

      call([[vim.cmd("ClaudeCodeOpen")]])

      local state = split_close_state()
      assert.equal(1, state.terminal_windows)
      assert.is_true(state.original_shows_file)
      assert.equal(2, state.windows)
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

  describe("a BufLeave autocmd that closes the other window of the file", function()
    ---A file of the user's with an edit, a hidden terminal, and a BufLeave autocmd of the user's file that closes the
    ---window that the file shows in. The autocmd runs in the split, which shows the file too, so the file loses its last
    ---window in the swap, and Neovim fires the events of that, nested or not.
    local function arm_window_close(opts)
      call(
        [[
        local opts = ...
        vim.o.hidden = opts.hidden
        local file = vim.api.nvim_get_current_buf()
        _G.file, _G.original = file, vim.api.nvim_get_current_win()
        _G.disk = _G.dir .. "/a.txt"
        local terminal = require("claudecode.terminal")
        terminal.open()
        for _, win in ipairs(vim.fn.win_findbuf(terminal.get_active_terminal_bufnr())) do
          vim.api.nvim_win_close(win, false)
        end
        _G.job = vim.b[terminal.get_active_terminal_bufnr()].terminal_job_id
        vim.bo[file].bufhidden = opts.bufhidden
        if opts.modified then
          vim.api.nvim_buf_set_lines(file, 0, -1, false, { "unsaved user edit" })
        end
        _G.events = {}
        for _, name in ipairs({ "BufWinLeave", "BufHidden", "BufUnload", "BufDelete", "BufWipeout" }) do
          vim.api.nvim_create_autocmd(name, {
            buffer = file,
            callback = function(event)
              table.insert(_G.events, name)
              if name == "BufHidden" then
                vim.api.nvim_buf_call(event.buf, function()
                  vim.cmd("silent update")
                end)
              end
            end,
          })
        end
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = file,
          once = true,
          nested = opts.nested,
          callback = function()
            _G.closed, _G.close_error = pcall(vim.api.nvim_win_close, _G.original, false)
          end,
        })
      ]],
        opts
      )
    end

    local function window_close_state()
      local state = call([[
        local terminal = require("claudecode.terminal")
        local buf = terminal.get_active_terminal_bufnr()
        local counts = {}
        for _, name in ipairs(_G.events) do
          counts[name] = (counts[name] or 0) + 1
        end
        return {
          counts = counts,
          closed = _G.closed,
          disk = vim.fn.readfile(_G.disk),
          file_loaded = vim.api.nvim_buf_is_valid(_G.file) and vim.api.nvim_buf_is_loaded(_G.file),
          file_valid = vim.api.nvim_buf_is_valid(_G.file),
          terminal_windows = #vim.fn.win_findbuf(buf),
          job_running = vim.fn.jobwait({ _G.job }, 10)[1] == -1,
        }
      ]])
      return state
    end

    for _, nested in ipairs({ false, true }) do
      local NESTED = nested
      local label = nested and " (a nested autocmd)" or " (an autocmd that is not nested)"
      it("lets the autosave of a BufHidden autocmd run, once, when the file stays loaded" .. label, function()
        start_child()
        arm_window_close({ hidden = true, bufhidden = "", modified = true, nested = NESTED })

        call([[require("claudecode.terminal").open()]])

        local state = window_close_state()
        assert.is_true(state.closed)
        assert.same({ BufWinLeave = 1, BufHidden = 1 }, state.counts)
        assert.same({ "unsaved user edit" }, state.disk, "the BufHidden autosave must write the edit")
        assert.is_true(state.file_loaded)
        assert.equal(1, state.terminal_windows)
        assert.is_true(state.job_running)
      end)

      it("fires the events of an unloaded file once each, when 'hidden' is off" .. label, function()
        start_child()
        arm_window_close({ hidden = false, bufhidden = "", modified = false, nested = NESTED })

        call([[require("claudecode.terminal").open()]])

        local state = window_close_state()
        assert.is_true(state.closed)
        assert.same({ BufWinLeave = 1, BufUnload = 1 }, state.counts)
        assert.is_false(state.file_loaded)
        assert.equal(1, state.terminal_windows)
        assert.is_true(state.job_running)
      end)

      it("fires the events of a wiped file once each, when its 'bufhidden' is wipe" .. label, function()
        start_child()
        arm_window_close({ hidden = true, bufhidden = "wipe", modified = false, nested = NESTED })

        call([[require("claudecode.terminal").open()]])

        local state = window_close_state()
        assert.is_true(state.closed)
        assert.same({ BufWinLeave = 1, BufUnload = 1, BufDelete = 1, BufWipeout = 1 }, state.counts)
        assert.is_false(state.file_valid)
        assert.equal(1, state.terminal_windows)
        assert.is_true(state.job_running)
      end)

      it("hides the unsaved file, and runs the events of that once, when 'hidden' is off" .. label, function()
        start_child()
        arm_window_close({ hidden = false, bufhidden = "", modified = true, nested = NESTED })

        call([[require("claudecode.terminal").open()]])

        local state = window_close_state()
        assert.is_true(state.closed, "the other window of the file is not its last, so Neovim closes it")
        assert.same({ BufWinLeave = 1, BufHidden = 1 }, state.counts)
        assert.same({ "unsaved user edit" }, state.disk, "the BufHidden autosave must write the edit")
        assert.is_true(state.file_loaded)
        assert.equal(1, state.terminal_windows)
        assert.is_true(state.job_running)
      end)
    end

    it("resolves a pending diff whose proposal buffer loses its last window", function()
      -- The proposal buffer of an openDiff is the buffer in the window, and a diff stays pending until its proposal is
      -- answered or hidden (#238).
      start_child()
      local state = call([[
        local diff = require("claudecode.diff")
        local tools = require("claudecode.tools.init")
        tools.register_all()
        _G.claude_deferred_responses = {}
        local terminal = require("claudecode.terminal")
        terminal.open()
        for _, win in ipairs(vim.fn.win_findbuf(terminal.get_active_terminal_bufnr())) do
          vim.api.nvim_win_close(win, false)
        end
        local path = _G.dir .. "/a.txt"
        local tab_name = "placement spec proposal"
        local answers = {}
        local call = tools.handle_invoke({ id = "placement_spec_client" }, {
          name = "openDiff",
          arguments = { old_file_path = path, new_file_path = path, new_file_contents = "changed\n", tab_name = tab_name },
        })
        _G.claude_deferred_responses[tostring(call.coroutine)] = function(response)
          table.insert(answers, response.content and response.content[1].text or vim.inspect(response))
        end
        local proposal = diff._get_active_diffs()[tab_name].new_buffer
        local proposal_windows = vim.fn.win_findbuf(proposal)
        vim.api.nvim_set_current_win(proposal_windows[1])
        -- The user's autocmd: leaving the proposal closes every window that shows it.
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = proposal,
          once = true,
          nested = true,
          callback = function(event)
            for _, win in ipairs(vim.fn.win_findbuf(event.buf)) do
              pcall(vim.api.nvim_win_close, win, true)
            end
          end,
        })
        local ok, err = pcall(function()
          terminal.open()
        end)
        vim.wait(300)
        local entry = diff._get_active_diffs()[tab_name]
        local buf = terminal.get_active_terminal_bufnr()
        return {
          ok = ok,
          err = tostring(err),
          resolved = (entry == nil or entry.status ~= "pending") and #answers > 0,
          terminal_windows = #vim.fn.win_findbuf(buf),
        }
      ]])

      assert.is_true(state.ok, state.err)
      assert.is_true(state.resolved, "the diff must resolve, as it does when its proposal is hidden by a plain swap")
      -- The autocmd closed the split too, so the terminal is shown nowhere. It runs on, as any hidden terminal does.
      assert.equal(0, state.terminal_windows)
    end)
  end)

  describe("a BufLeave autocmd that shows the leaving buffer in another window", function()
    it("does not run the BufHidden cleanup of a scratch buffer that is still visible", function()
      -- Another plugin's BufEnter puts a scratch buffer with unsaved text into the new terminal's split. When the swap
      -- after `termopen` leaves it, its BufLeave autocmd shows it in the user's window, so it never loses its last window.
      start_child()
      local state = call([[
        local original = vim.api.nvim_get_current_win()
        local scratch, hidden_count
        vim.api.nvim_create_autocmd("BufEnter", {
          once = true,
          callback = function()
            scratch = vim.api.nvim_create_buf(true, true)
            vim.api.nvim_buf_set_name(scratch, "USER-SCRATCH")
            vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "UNSAVED SCRATCH TEXT" })
            vim.api.nvim_set_current_buf(scratch)
            vim.api.nvim_create_autocmd("BufLeave", {
              buffer = scratch,
              once = true,
              nested = true,
              callback = function()
                vim.api.nvim_win_set_buf(original, scratch)
              end,
            })
            vim.api.nvim_create_autocmd("BufHidden", {
              buffer = scratch,
              callback = function(event)
                hidden_count = (hidden_count or 0) + 1
                vim.cmd("bwipeout " .. event.buf)
              end,
            })
          end,
        })
        local ok, err = pcall(function()
          require("claudecode.terminal").open()
        end)
        local terminal = require("claudecode.terminal")
        local buf = terminal.get_active_terminal_bufnr()
        return {
          ok = ok,
          err = tostring(err),
          hidden_count = hidden_count or 0,
          scratch_text = vim.api.nvim_buf_is_valid(scratch) and table.concat(vim.api.nvim_buf_get_lines(scratch, 0, -1, false), "|") or "GONE",
          original_shows_scratch = vim.api.nvim_win_get_buf(original) == scratch,
          terminal_windows = buf and #vim.fn.win_findbuf(buf) or 0,
        }
      ]])

      assert.is_true(state.ok, state.err)
      assert.equal(0, state.hidden_count)
      assert.equal("UNSAVED SCRATCH TEXT", state.scratch_text)
      assert.is_true(state.original_shows_scratch)
    end)
  end)
end)

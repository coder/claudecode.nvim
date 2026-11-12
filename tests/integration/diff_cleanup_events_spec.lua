-- OptionSet does not fire while Neovim is still starting, and a spec that plenary starts with -c runs in that state.
-- The cleanup tells diff mode that a command turned on from diff mode that a split copied by that event, and the user's
-- handlers run when a window falls back to the file, so each case runs in a child Neovim that is driven over RPC.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the cleanup of a split diff and the user's own diff mode and handlers", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("the cleanup of a split diff and the user's own diff mode and handlers", function()
  local chan

  local function call(code, ...)
    return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
  end

  -- One child Neovim serves the whole file, and each case starts from a clean editor in it.
  before_each(function()
    if not chan then
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
    end
    call([[
      vim.o.swapfile = false
      vim.o.columns, vim.o.lines = 160, 40
      local diff = require("claudecode.diff")
      local tools = require("claudecode.tools.init")
      pcall(diff._cleanup_all_active_diffs, "spec reset")
      vim.cmd("silent! tabonly!")
      vim.cmd("silent! only!")
      vim.cmd("silent! %bwipeout!")
      vim.api.nvim_create_augroup("events_spec", { clear = true })
      vim.o.eventignore = ""
      _G.armed, _G.fired, _G.target = nil, nil, nil
      _G.dir = vim.fn.tempname()
      vim.fn.mkdir(_G.dir, "p")
      _G.file = _G.dir .. "/existing.txt"
      _G.other = _G.dir .. "/other.txt"
      vim.fn.writefile({ "one", "two" }, _G.file)
      vim.fn.writefile({ "other" }, _G.other)
      vim.cmd("edit " .. vim.fn.fnameescape(_G.file))
      tools.setup()
      diff.setup({ terminal = { provider = "none" }, diff_opts = { layout = "vertical" } })
      _G.claude_deferred_responses = {}
      local tab = "✻ [Claude Code] events.txt ⧉"
      function _G.open_diff()
        local call = tools.handle_invoke({ id = "events" }, {
          name = "openDiff",
          arguments = { old_file_path = _G.file, new_file_path = _G.file, new_file_contents = "one\nTWO\n", tab_name = tab },
        })
        assert(call._deferred, "openDiff waits for the user")
        _G.claude_deferred_responses[tostring(call.coroutine)] = function() end
        return diff._get_active_diffs()[tab]
      end
      function _G.close_tab()
        tools.handle_invoke({ id = "events" }, { name = "close_tab", arguments = { tab_name = tab } })
        vim.wait(50)
      end
      function _G.opt(win, name)
        return vim.api.nvim_get_option_value(name, { win = win })
      end
      function _G.diff_windows()
        local count = 0
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if _G.opt(win, "diff") then
            count = count + 1
          end
        end
        return count
      end
    ]])
  end)

  describe("a window that gets diff mode from a command while the diff is open", function()
    it("keeps it when the user runs :diffoff and :diffthis in a :split copy of the original window", function()
      local result = call([[
        local state = _G.open_diff()
        vim.api.nvim_set_current_win(state.target_window)
        vim.cmd("split")
        local copy = vim.api.nvim_get_current_win()
        vim.cmd("diffoff | diffthis")
        _G.close_tab()
        return { diff = _G.opt(copy, "diff"), count = _G.diff_windows() }
      ]])

      assert.is_true(result.diff, "the user's own diff mode stays, as on main")
      assert.equal(1, result.count)
    end)

    it("ends the diff mode that a :split copy took from the original window with no command", function()
      local result = call([[
        local state = _G.open_diff()
        vim.api.nvim_set_current_win(state.target_window)
        vim.cmd("split")
        local copy = vim.api.nvim_get_current_win()
        _G.close_tab()
        return { diff = _G.opt(copy, "diff"), count = _G.diff_windows() }
      ]])

      assert.is_false(result.diff, "a copy that has no partner has the leftover of the ended diff")
      assert.equal(0, result.count)
    end)
  end)

  describe("a window of another tab page that has diff mode after the diff", function()
    local new_tab_commands = {
      { name = ":tabnew <file>", code = 'vim.cmd("tabnew " .. vim.fn.fnameescape(_G.file))' },
      { name = ":tabnew and :buffer <file>", code = 'vim.cmd("tabnew"); vim.cmd("buffer " .. vim.fn.bufnr(_G.file))' },
      { name = ":tab sbuffer <file>", code = 'vim.cmd("tab sbuffer " .. vim.fn.bufnr(_G.file))' },
    }

    for _, command in ipairs(new_tab_commands) do
      it("gets no diff mode from " .. command.name .. " while the diff is open", function()
        local result = call(
          [[
          local code = ...
          _G.open_diff()
          local first_tab = vim.api.nvim_get_current_tabpage()
          load(code)()
          local window = vim.api.nvim_get_current_win()
          local diff = _G.opt(window, "diff")
          vim.api.nvim_set_current_tabpage(first_tab)
          _G.close_tab()
          local next_diff = _G.open_diff()
          return { diff = diff, after = _G.opt(window, "diff"), new_tab = next_diff.created_new_tab }
        ]],
          command.code
        )

        assert.is_false(result.diff, "the plugin splits before diffthis, so no saved set for the file has diff mode")
        assert.is_false(result.after)
        assert.is_falsy(result.new_tab, "the next diff opens in the tab where it was asked for")
      end)
    end

    it("loses the diff mode that :tab split copied from the original window", function()
      local result = call([[
        local state = _G.open_diff()
        vim.api.nvim_set_current_win(state.target_window)
        vim.cmd("tab split")
        local window = vim.api.nvim_get_current_win()
        local copied = _G.opt(window, "diff")
        vim.cmd("tabprevious")
        _G.close_tab()
        return { copied = copied, diff = _G.opt(window, "diff") }
      ]])

      assert.is_true(result.copied)
      assert.is_false(result.diff)
    end)

    it("keeps the diff mode that the user turns on with :diffthis there while the diff is open", function()
      local result = call([[
        local state = _G.open_diff()
        local first_tab = vim.api.nvim_get_current_tabpage()
        vim.cmd("tabnew " .. vim.fn.fnameescape(_G.file))
        local window = vim.api.nvim_get_current_win()
        vim.cmd("diffthis")
        vim.api.nvim_set_current_tabpage(first_tab)
        _G.close_tab()
        return { diff = _G.opt(window, "diff") }
      ]])

      assert.is_true(result.diff, "the user's own diff mode stays, as on main")
    end)

    it("keeps the diff mode that the user turned on there before the diff opened", function()
      local result = call([[
        vim.cmd("tabnew " .. vim.fn.fnameescape(_G.file))
        local window = vim.api.nvim_get_current_win()
        vim.cmd("diffthis")
        vim.cmd("tabprevious")
        local state = _G.open_diff()
        _G.close_tab()
        return { diff = _G.opt(window, "diff") }
      ]])

      assert.is_true(result.diff, "diff mode that was on before the diff opened is the user's")
    end)

    it("keeps two windows there that the user compares", function()
      local result = call([[
        local state = _G.open_diff()
        local first_tab = vim.api.nvim_get_current_tabpage()
        vim.cmd("tabnew " .. vim.fn.fnameescape(_G.file))
        local first = vim.api.nvim_get_current_win()
        vim.cmd("vsplit " .. vim.fn.fnameescape(_G.other))
        local second = vim.api.nvim_get_current_win()
        vim.cmd("windo diffthis")
        vim.api.nvim_set_current_tabpage(first_tab)
        _G.close_tab()
        return { first = _G.opt(first, "diff"), second = _G.opt(second, "diff") }
      ]])

      assert.is_true(result.first)
      assert.is_true(result.second)
    end)
  end)

  describe("the events of the proposal buffer that the cleanup deletes", function()
    it(
      "still run the handlers of the user's that leave and unload the proposal, and the ones that enter the file run last",
      function()
        local result = call([[
        local state = _G.open_diff()
        vim.api.nvim_set_current_win(state.target_window)
        vim.cmd("buffer " .. state.new_buffer)
        local seen = {}
        for _, event in ipairs({ "BufLeave", "BufWinLeave", "BufUnload", "BufWipeout", "BufEnter", "BufWinEnter" }) do
          vim.api.nvim_create_autocmd(event, {
            group = "events_spec",
            callback = function(args)
              if _G.armed then
                local name = vim.api.nvim_buf_get_name(args.buf)
                seen[#seen + 1] = event .. ":" .. (name:find("(proposed)", 1, true) and "proposal" or name:match("[^/]*$"))
              end
            end,
          })
        end
        _G.armed = true
        _G.close_tab()
        _G.armed = false
        return seen
      ]])

        assert.same({
          "BufLeave:proposal",
          "BufWinLeave:proposal",
          "BufUnload:proposal",
          "BufWipeout:proposal",
          "BufEnter:existing.txt",
          "BufWinEnter:existing.txt",
        }, result)
      end
    )
  end)

  describe("a window that falls back to the file when the proposal buffer is deleted", function()
    local handler_cases = {
      {
        action = "own_diff",
        handler = 'vim.cmd("diffoff"); vim.cmd("diffthis"); vim.cmd("setlocal foldmethod=indent scrollbind nowrap")',
        expect = { diff = true, foldmethod = "indent", scrollbind = true, wrap = false },
        later_partner = true,
      },
      {
        action = "diffthis only",
        handler = 'vim.cmd("diffthis")',
        expect = { diff = true },
        later_partner = true,
      },
      {
        action = "foldmethod only",
        handler = 'vim.cmd("setlocal foldmethod=indent")',
        expect = { diff = false, foldmethod = "indent" },
      },
      {
        action = "foldmethod, scrollbind and wrap",
        handler = 'vim.cmd("setlocal foldmethod=indent scrollbind nowrap")',
        expect = { diff = false, foldmethod = "indent", scrollbind = true, wrap = false },
      },
      {
        action = "a comparison that it starts at once",
        handler = 'vim.cmd("diffoff"); vim.cmd("diffthis"); vim.cmd("setlocal foldmethod=indent scrollbind nowrap"); '
          .. 'vim.cmd("vert diffsplit " .. vim.fn.fnameescape(_G.other))',
        expect = { diff = true, foldmethod = "diff", count = 2 },
      },
    }

    local function run(event, handler, before_open)
      return call(
        [[
        local event, handler, before_open = ...
        local function register()
          _G.armed = false
          vim.api.nvim_create_autocmd(event, {
            group = "events_spec",
            callback = function()
              if _G.armed and vim.api.nvim_get_current_win() == _G.target and vim.api.nvim_buf_get_name(0) == _G.file then
                _G.armed = false
                _G.fired = (_G.fired or 0) + 1
                load(handler)()
              end
            end,
          })
        end
        if before_open then
          register()
        end
        local state = _G.open_diff()
        if not before_open then
          register()
        end
        _G.target = state.target_window
        vim.api.nvim_set_current_win(_G.target)
        vim.cmd("buffer " .. state.new_buffer)
        _G.armed = true
        _G.close_tab()
        local window = _G.target
        return {
          fired = _G.fired or 0,
          windows = #vim.api.nvim_list_wins(),
          shows_file = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(window)) == _G.file,
          diff = _G.opt(window, "diff"),
          foldmethod = _G.opt(window, "foldmethod"),
          scrollbind = _G.opt(window, "scrollbind"),
          wrap = _G.opt(window, "wrap"),
          count = _G.diff_windows(),
          eventignore = vim.o.eventignore,
        }
      ]],
        event,
        handler,
        before_open or false
      )
    end

    for _, event in ipairs({ "BufEnter", "BufWinEnter" }) do
      it("leaves no diff mode in the window when no handler of " .. event .. " runs", function()
        local result = run(event, "", false)

        assert.equal(1, result.fired, "the handler ran")
        assert.is_true(result.shows_file)
        assert.is_false(result.diff)
        assert.equal(0, result.count)
        assert.equal("", result.eventignore, "the cleanup gives 'eventignore' back")
      end)

      for _, case in ipairs(handler_cases) do
        it("keeps what a " .. event .. " handler sets: " .. case.action, function()
          local result = run(event, case.handler, false)

          assert.equal(1, result.fired, "the handler ran once")
          assert.is_true(result.shows_file)
          for name, value in pairs(case.expect) do
            assert.equal(value, result[name], "'" .. name .. "' is what the handler set")
          end
        end)

        if case.later_partner then
          it(
            "compares with a window that the user adds later, after a " .. event .. " handler: " .. case.action,
            function()
              local result = call(
                [[
              local event, handler = ...
              vim.api.nvim_create_autocmd(event, {
            group = "events_spec",
                callback = function()
                  if _G.armed and vim.api.nvim_get_current_win() == _G.target and vim.api.nvim_buf_get_name(0) == _G.file then
                    _G.armed = false
                    load(handler)()
                  end
                end,
              })
              local state = _G.open_diff()
              _G.target = state.target_window
              vim.api.nvim_set_current_win(_G.target)
              vim.cmd("buffer " .. state.new_buffer)
              _G.armed = true
              _G.close_tab()
              vim.cmd("vsplit " .. vim.fn.fnameescape(_G.other))
              vim.cmd("diffthis")
              return { target = _G.opt(_G.target, "diff"), partner = _G.opt(vim.api.nvim_get_current_win(), "diff"), count = _G.diff_windows() }
            ]],
                event,
                case.handler
              )

              assert.is_true(result.target, "the window that the handler put in diff mode is compared")
              assert.is_true(result.partner)
              assert.equal(2, result.count)
            end
          )
        end
      end

      it("runs the " .. event .. " handlers once when the closed window hands the focus to another window", function()
        local result = call(
          [[
          local event = ...
          local state = _G.open_diff()
          vim.api.nvim_set_current_win(state.target_window)
          vim.cmd("buffer " .. state.new_buffer)
          vim.cmd("split")
          local seen = {}
          vim.api.nvim_create_autocmd(event, {
            group = "events_spec",
            callback = function()
              if _G.armed then
                seen[#seen + 1] = vim.api.nvim_buf_get_name(0):match("[^/]*$") .. "@" .. (vim.api.nvim_get_current_win() == state.target_window and "target" or "other")
              end
            end,
          })
          _G.armed = true
          _G.close_tab()
          _G.armed = false
          return { seen = seen, windows = #vim.api.nvim_list_wins(), eventignore = vim.o.eventignore }
        ]],
          event
        )

        assert.equal(1, result.windows, "the window that showed the proposal closed")
        assert.same({ "existing.txt@target" }, result.seen)
        assert.equal("", result.eventignore, "the cleanup gives 'eventignore' back")
      end)

      it(
        "runs the "
          .. event
          .. " handlers for the window that gets the focus when the window that showed the proposal closes",
        function()
          local result = call(
            [[
          local event = ...
          local state = _G.open_diff()
          vim.api.nvim_set_current_win(state.target_window)
          vim.cmd("buffer " .. state.new_buffer)
          vim.cmd("botright vsplit " .. vim.fn.fnameescape(_G.other))
          vim.api.nvim_set_current_win(state.target_window)
          local seen = {}
          vim.api.nvim_create_autocmd(event, {
            group = "events_spec",
            callback = function()
              if _G.armed then
                seen[#seen + 1] = vim.api.nvim_buf_get_name(0):match("[^/]*$")
              end
            end,
          })
          _G.armed = true
          _G.close_tab()
          _G.armed = false
          return { seen = seen, windows = #vim.api.nvim_list_wins(), eventignore = vim.o.eventignore }
        ]],
            event
          )

          assert.equal(1, result.windows, "the window that showed the proposal closed")
          assert.same(event == "BufEnter" and { "other.txt" } or {}, result.seen)
          assert.equal("", result.eventignore)
        end
      )

      it("ends the leftover and keeps a foldmethod that a " .. event .. " handler sets on every entry", function()
        local result = run(event, 'vim.cmd("setlocal foldmethod=indent")', true)

        assert.equal(1, result.fired)
        assert.is_false(result.diff)
        assert.equal("indent", result.foldmethod)
      end)
    end
  end)
end)

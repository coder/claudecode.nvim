if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the native terminal's swap into its own split", function()
    pending("needs a real Neovim")
  end)
  return
end

-- Neovim loads a buffer into the window that a BufLeave autocmd entered while `nvim_win_set_buf` runs, even when the call
-- names another window. A user autocmd of that kind must not make the provider put the terminal into the user's window.
-- The provider lets every autocmd of its swaps run, so a BufLeave autosave of the user's still runs and no OptionSet
-- autocmd sees a change of 'eventignore'.
describe("the native terminal's swap into its own split", function()
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
      vim.cmd("edit " .. _G.dir .. "/a.txt")
      require("claudecode").setup({
        auto_start = false,
        log_level = "error",
        terminal_cmd = "sleep 3600",
        terminal = { provider = "native" },
      })
    ]])
  end

  ---An edited file of the user's in a window above the current one. The cursor stays in the window it was in.
  local function open_user_window()
    return call([[
      local start = vim.api.nvim_get_current_win()
      vim.cmd("topleft split " .. vim.fn.fnameescape(_G.dir .. "/other.txt"))
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

  ---Another plugin's BufEnter swaps a scratch buffer of its own into the split when the new terminal buffer is entered,
  ---so the provider's repair swap runs. Only the BufLeave of that scratch buffer enters the user's window.
  local function arm_repair_swap(every_time)
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
        local lines = open_user_window()
        arm_repair_swap(every_time)

        call([[require("claudecode.terminal").ensure_visible()]])

        expect_user_window_kept(lines)
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

  it("runs no autocmd for the two swaps that repair a redirect", function()
    start_child()

    local runs = call([[
      local utils = require("claudecode.utils")
      local function run(repair)
        vim.cmd("tabnew")
        local file = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(0, file)
        local user_win = vim.api.nvim_get_current_win()
        vim.cmd("vsplit")
        local split = vim.api.nvim_get_current_win()
        local terminal = vim.api.nvim_create_buf(true, false)
        local roles = { [file] = "file", [terminal] = "terminal" }
        local log = {}
        local group = vim.api.nvim_create_augroup("swap_events_" .. tostring(repair), { clear = true })
        local events = { "BufLeave", "BufEnter", "BufWinEnter", "BufWinLeave", "BufHidden", "WinEnter", "WinLeave" }
        vim.api.nvim_create_autocmd(events, {
          group = group,
          callback = function(event)
            table.insert(log, event.event .. "@" .. (roles[event.buf] or "other"))
          end,
        })
        vim.api.nvim_create_autocmd("BufLeave", {
          group = group,
          buffer = file,
          once = true,
          callback = function()
            vim.api.nvim_set_current_win(user_win)
          end,
        })
        if repair then
          utils.win_set_buf_in_split(split, terminal)
        else
          vim.api.nvim_win_set_buf(split, terminal)
        end
        vim.api.nvim_clear_autocmds({ group = group })
        return {
          log = log,
          user_win_shows = roles[vim.api.nvim_win_get_buf(user_win)],
          split_shows = roles[vim.api.nvim_win_get_buf(split)],
        }
      end
      return { plain = run(false), repaired = run(true) }
    ]])

    assert.equal("terminal", runs.plain.user_win_shows, "a plain swap is redirected, or the test proves nothing")
    assert.equal("file", runs.repaired.user_win_shows)
    assert.equal("terminal", runs.repaired.split_shows)
    assert.same(runs.plain.log, runs.repaired.log)
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
      assert.is_true(state.autosaves >= 1)
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

    it("never runs while the repair swap shows the new terminal in its split", function()
      start_child()
      open_user_window()
      arm_repair_swap(false)
      arm_option_set_autocmd()

      call([[require("claudecode.terminal").ensure_visible()]])

      expect_no_option_write()
    end)
  end)
end)

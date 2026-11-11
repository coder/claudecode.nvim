if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the native terminal's swap into its own split", function()
    pending("needs a real Neovim")
  end)
  return
end

-- Neovim loads a buffer into the window that a BufLeave autocmd entered while `nvim_win_set_buf` runs, even when the call
-- names another window. A user autocmd of that kind must not make the provider put the terminal into the user's window.
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
      call([[
        require("claudecode.terminal").open()
        for _, win in ipairs(vim.fn.win_findbuf(require("claudecode.terminal").get_active_terminal_bufnr())) do
          vim.api.nvim_win_close(win, false)
        end
      ]])
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
  end
end)

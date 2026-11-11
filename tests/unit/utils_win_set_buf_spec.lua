require("tests.busted_setup")

describe("claudecode.utils.win_set_buf_without_bufenter", function()
  local utils = require("claudecode.utils")
  local real_set_buf
  local calls

  before_each(function()
    real_set_buf = vim.api.nvim_win_set_buf
    calls = {}
    vim.o.eventignore = ""
    vim.api.nvim_win_set_buf = function(win, buf)
      table.insert(calls, { win = win, buf = buf, eventignore = vim.o.eventignore })
    end
  end)

  after_each(function()
    vim.api.nvim_win_set_buf = real_set_buf
    vim.o.eventignore = ""
  end)

  it("sets the buffer in the window", function()
    utils.win_set_buf_without_bufenter(1001, 7)

    assert.equal(1, #calls)
    assert.equal(1001, calls[1].win)
    assert.equal(7, calls[1].buf)
  end)

  it("ignores BufEnter for the call and gives 'eventignore' back", function()
    utils.win_set_buf_without_bufenter(1001, 7)

    assert.equal("BufEnter", calls[1].eventignore)
    assert.equal("", vim.o.eventignore)
  end)

  it("keeps the other events the user ignores", function()
    vim.o.eventignore = "CursorHold,WinEnter"

    utils.win_set_buf_without_bufenter(1001, 7)

    assert.equal("CursorHold,WinEnter,BufEnter", calls[1].eventignore)
    assert.equal("CursorHold,WinEnter", vim.o.eventignore)
  end)

  it("drops a -BufEnter entry for the call, because it would beat a later BufEnter", function()
    vim.o.eventignore = "all,-bufenter,CursorHold"

    utils.win_set_buf_without_bufenter(1001, 7)

    assert.equal("all,CursorHold,BufEnter", calls[1].eventignore)
    assert.equal("all,-bufenter,CursorHold", vim.o.eventignore)
  end)

  it("gives 'eventignore' back and raises the same error when the buffer cannot be set", function()
    vim.api.nvim_win_set_buf = function()
      error("E5555: Invalid window id", 0)
    end
    vim.o.eventignore = "CursorHold"

    local ok, err = pcall(utils.win_set_buf_without_bufenter, 1001, 7)

    assert.is_false(ok)
    assert.equal("E5555: Invalid window id", err)
    assert.equal("CursorHold", vim.o.eventignore)
  end)
end)

describe("claudecode.utils.win_set_buf_in_split", function()
  local utils = require("claudecode.utils")
  local USER_WIN, SPLIT_WIN = 1000, 1001
  local USER_BUF, TERM_BUF = 5, 9
  local original = {}
  local shown
  local commands
  local option_writes
  local bufhidden
  local hidden

  local function stub(table_, name, value)
    original[#original + 1] = { table_, name, table_[name] }
    table_[name] = value
  end

  before_each(function()
    original = {}
    shown = { [USER_WIN] = USER_BUF, [SPLIT_WIN] = USER_BUF }
    commands = {}
    option_writes = 0
    bufhidden = "hide"
    hidden = true

    stub(vim.api, "nvim_list_wins", function()
      local wins = {}
      for win in pairs(shown) do
        table.insert(wins, win)
      end
      table.sort(wins)
      return wins
    end)
    stub(vim.api, "nvim_win_get_buf", function(win)
      assert(shown[win], "Invalid window id: " .. tostring(win))
      return shown[win]
    end)
    stub(vim.api, "nvim_win_is_valid", function(win)
      return shown[win] ~= nil
    end)
    stub(vim.api, "nvim_buf_get_option", function(buf, name)
      assert(buf == TERM_BUF and name == "bufhidden", "unexpected option read")
      return bufhidden
    end)
    stub(vim.api, "nvim_win_set_buf", function(win, buf)
      shown[win] = buf
    end)
    stub(vim, "cmd", function(command)
      table.insert(commands, command)
      local win, buf = command:match("^noautocmd call nvim_win_set_buf%((%d+), (%d+)%)$")
      assert(win, "unexpected command: " .. command)
      shown[tonumber(win)] = tonumber(buf)
    end)
    stub(
      vim,
      "o",
      setmetatable({}, {
        __index = function(_, key)
          if key == "hidden" then
            return hidden
          end
          return ""
        end,
        __newindex = function()
          option_writes = option_writes + 1
        end,
      })
    )
  end)

  after_each(function()
    for index = #original, 1, -1 do
      local table_, name, value = unpack(original[index])
      table_[name] = value
    end
  end)

  ---A BufLeave autocmd of the user's enters their window inside the swap, and Neovim loads the buffer into that window.
  local function swap_redirected_to_user_window(_, buf)
    shown[USER_WIN] = buf
  end

  describe(
    "a swap that a BufLeave autocmd redirected into a window that showed the same buffer as the split",
    function()
      it("puts that window's buffer back, then shows the buffer in its own window, both without autocmds", function()
        utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, swap_redirected_to_user_window)

        assert.same({
          "noautocmd call nvim_win_set_buf(1000, 5)",
          "noautocmd call nvim_win_set_buf(1001, 9)",
        }, commands)
        assert.equal(USER_BUF, shown[USER_WIN])
        assert.equal(TERM_BUF, shown[SPLIT_WIN])
      end)

      it("repairs when another window already showed the buffer before the swap, and keeps that window", function()
        shown[1002] = TERM_BUF

        utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, swap_redirected_to_user_window)

        assert.same({
          "noautocmd call nvim_win_set_buf(1000, 5)",
          "noautocmd call nvim_win_set_buf(1001, 9)",
        }, commands)
        assert.equal(TERM_BUF, shown[1002])
      end)

      it("writes no option", function()
        utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, swap_redirected_to_user_window)

        assert.equal(0, option_writes)
      end)

      it("leaves the buffer where Neovim put it when putting the other window's buffer back fails", function()
        vim.cmd = function()
          error("E37: No write since last change")
        end

        local ok = pcall(utils.win_set_buf_in_split, SPLIT_WIN, TERM_BUF, swap_redirected_to_user_window)

        assert.is_true(ok)
        assert.equal(TERM_BUF, shown[USER_WIN])
        assert.equal(USER_BUF, shown[SPLIT_WIN])
      end)

      it("repairs a buffer with 'bufhidden' set to hide, also while 'hidden' is not set", function()
        hidden = false

        utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, swap_redirected_to_user_window)

        assert.equal(TERM_BUF, shown[SPLIT_WIN])
      end)

      it("repairs a buffer with an empty 'bufhidden' while 'hidden' is set", function()
        bufhidden = ""

        utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, swap_redirected_to_user_window)

        assert.equal(TERM_BUF, shown[SPLIT_WIN])
      end)

      local keeps = {
        { name = "an empty 'bufhidden' while 'hidden' is not set", bufhidden = "", hidden = false },
        { name = "'bufhidden' set to wipe", bufhidden = "wipe", hidden = true },
        { name = "'bufhidden' set to delete", bufhidden = "delete", hidden = true },
        { name = "'bufhidden' set to unload", bufhidden = "unload", hidden = true },
      }
      for _, case in ipairs(keeps) do
        it("does what a plain swap does for a buffer with " .. case.name, function()
          bufhidden = case.bufhidden
          hidden = case.hidden

          utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, swap_redirected_to_user_window)

          assert.same({}, commands)
          assert.equal(TERM_BUF, shown[USER_WIN])
          assert.equal(USER_BUF, shown[SPLIT_WIN])
        end)
      end

      it("does what a plain swap does when two windows got the buffer", function()
        shown[1002] = USER_BUF

        utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, function(_, buf)
          shown[USER_WIN] = buf
          shown[1002] = buf
        end)

        assert.same({}, commands)
        assert.equal(TERM_BUF, shown[USER_WIN])
        assert.equal(TERM_BUF, shown[1002])
        assert.equal(USER_BUF, shown[SPLIT_WIN])
      end)
    end
  )

  describe("every other shape keeps what a plain swap does", function()
    it("for a redirect into a window that showed another buffer", function()
      shown[USER_WIN] = 6

      utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, swap_redirected_to_user_window)

      assert.same({}, commands)
      assert.equal(TERM_BUF, shown[USER_WIN])
      assert.equal(USER_BUF, shown[SPLIT_WIN])
    end)

    it("for a window that the autocmd created", function()
      utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, function(_, buf)
        shown[1002] = buf
      end)

      assert.same({}, commands)
      assert.equal(TERM_BUF, shown[1002])
      assert.equal(USER_BUF, shown[SPLIT_WIN])
    end)

    it("for a window that already showed the buffer before the swap", function()
      shown[USER_WIN] = TERM_BUF

      utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, function() end)

      assert.same({}, commands)
      assert.equal(TERM_BUF, shown[USER_WIN])
      assert.equal(USER_BUF, shown[SPLIT_WIN])
    end)

    it("when an autocmd closed the window that the swap was for", function()
      utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, function(_, buf)
        shown[USER_WIN] = buf
        shown[SPLIT_WIN] = nil
      end)

      assert.same({}, commands)
      assert.equal(TERM_BUF, shown[USER_WIN])
    end)

    it("when another window got the buffer and the window got it too, as for a mirror", function()
      utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, function(win, buf)
        shown[win] = buf
        shown[USER_WIN] = buf
      end)

      assert.same({}, commands)
      assert.equal(TERM_BUF, shown[USER_WIN])
      assert.equal(TERM_BUF, shown[SPLIT_WIN])
    end)

    it("when the window showed the buffer before the swap and still does", function()
      shown[SPLIT_WIN] = TERM_BUF

      utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF)

      assert.same({}, commands)
      assert.equal(TERM_BUF, shown[SPLIT_WIN])
    end)

    it("when another autocmd put its own buffer into the window in place of the buffer", function()
      utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, function(win)
        shown[win] = 7
      end)

      assert.same({}, commands)
      assert.equal(7, shown[SPLIT_WIN])
    end)
  end)

  it("shows the buffer in the window with nvim_win_set_buf and runs no command", function()
    utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF)

    assert.equal(TERM_BUF, shown[SPLIT_WIN])
    assert.equal(USER_BUF, shown[USER_WIN])
    assert.same({}, commands)
  end)

  it("uses the swap it is given in place of nvim_win_set_buf", function()
    local given = {}
    vim.api.nvim_win_set_buf = function()
      error("nvim_win_set_buf must not run")
    end

    utils.win_set_buf_in_split(SPLIT_WIN, TERM_BUF, function(win, buf)
      table.insert(given, { win, buf })
      shown[win] = buf
    end)

    assert.same({ { SPLIT_WIN, TERM_BUF } }, given)
    assert.equal(TERM_BUF, shown[SPLIT_WIN])
  end)

  it("raises the error of the swap and repairs nothing", function()
    local ok, err = pcall(utils.win_set_buf_in_split, SPLIT_WIN, TERM_BUF, function(_, buf)
      shown[USER_WIN] = buf
      error("E5555: a BufLeave autocmd failed", 0)
    end)

    assert.is_false(ok)
    assert.equal("E5555: a BufLeave autocmd failed", err)
    assert.same({}, commands)
  end)
end)

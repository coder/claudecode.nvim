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

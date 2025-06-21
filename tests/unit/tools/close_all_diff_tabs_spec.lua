require("tests.busted_setup") -- Ensure test helpers are loaded

describe("Tool: close_all_diff_tabs", function()
  local close_all_diff_tabs_handler

  before_each(function()
    package.loaded["claudecode.tools.close_all_diff_tabs"] = nil
    close_all_diff_tabs_handler = require("claudecode.tools.close_all_diff_tabs").handler

    _G.vim = _G.vim or {}
    _G.vim.api = _G.vim.api or {}
    _G.vim.fn = _G.vim.fn or {}

    -- Default mocks
    _G.vim.api.nvim_list_wins = spy.new(function()
      return {}
    end)
    _G.vim.api.nvim_win_get_buf = spy.new(function()
      return 1
    end)
    _G.vim.api.nvim_buf_get_option = spy.new(function()
      return ""
    end)
    _G.vim.api.nvim_win_get_option = spy.new(function()
      return false
    end)
    _G.vim.api.nvim_buf_get_name = spy.new(function()
      return ""
    end)
    _G.vim.api.nvim_list_bufs = spy.new(function()
      return {}
    end)
    _G.vim.api.nvim_buf_is_loaded = spy.new(function()
      return false
    end)
    _G.vim.api.nvim_win_is_valid = spy.new(function()
      return true
    end)
    _G.vim.api.nvim_win_close = spy.new(function()
      return true
    end)
    _G.vim.api.nvim_buf_delete = spy.new(function()
      return true
    end)
    _G.vim.fn.win_findbuf = spy.new(function()
      return {}
    end)
  end)

  after_each(function()
    package.loaded["claudecode.tools.close_all_diff_tabs"] = nil
    -- Clear all mocks
    _G.vim.api.nvim_list_wins = nil
    _G.vim.api.nvim_win_get_buf = nil
    _G.vim.api.nvim_buf_get_option = nil
    _G.vim.api.nvim_win_get_option = nil
    _G.vim.api.nvim_buf_get_name = nil
    _G.vim.api.nvim_list_bufs = nil
    _G.vim.api.nvim_buf_is_loaded = nil
    _G.vim.api.nvim_win_is_valid = nil
    _G.vim.api.nvim_win_close = nil
    _G.vim.api.nvim_buf_delete = nil
    _G.vim.fn.win_findbuf = nil
  end)

  it("should return CLOSED_0_DIFF_TABS when no diff tabs found", function()
    local success, result = pcall(close_all_diff_tabs_handler, {})
    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")
    expect(result.content[1].text).to_be("CLOSED_0_DIFF_TABS")
  end)

  it("should close windows in diff mode", function()
    _G.vim.api.nvim_list_wins = spy.new(function()
      return { 1, 2 }
    end)
    _G.vim.api.nvim_win_get_option = spy.new(function(win, opt)
      if opt == "diff" then
        return win == 1 -- Only window 1 is in diff mode
      end
      return false
    end)

    local success, result = pcall(close_all_diff_tabs_handler, {})
    expect(success).to_be_true()
    expect(result.content[1].text).to_be("CLOSED_1_DIFF_TABS")
    assert.spy(_G.vim.api.nvim_win_close).was_called_with(1, false)
  end)

  it("should close diff-related buffers", function()
    _G.vim.api.nvim_list_bufs = spy.new(function()
      return { 1, 2 }
    end)
    _G.vim.api.nvim_buf_is_loaded = spy.new(function()
      return true
    end)
    _G.vim.api.nvim_buf_get_name = spy.new(function(buf)
      if buf == 1 then
        return "/path/to/file.diff"
      end
      if buf == 2 then
        return "/path/to/normal.txt"
      end
      return ""
    end)
    _G.vim.fn.win_findbuf = spy.new(function()
      return {} -- No windows for these buffers
    end)

    local success, result = pcall(close_all_diff_tabs_handler, {})
    expect(success).to_be_true()
    expect(result.content[1].text).to_be("CLOSED_1_DIFF_TABS")
    assert.spy(_G.vim.api.nvim_buf_delete).was_called_with(1, { force = true })
  end)
end)

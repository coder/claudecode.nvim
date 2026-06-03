-- Regression test for Snacks provider command handling.
--
-- The Snacks provider must pass the Claude command to Snacks.terminal.open as an
-- argv list, NOT a shell string. As a string, Snacks hands it to the shell,
-- which glob-expands bracketed model aliases such as "opus[1m]" (zsh aborts with
-- "no matches found"), preventing Claude from launching. See snacks.lua M.open.

describe("claudecode.terminal.snacks command handling", function()
  local snacks_provider
  local original_vim
  local spy
  local captured
  local mock_snacks

  local function make_term_instance()
    return {
      buf = 1,
      win = nil,
      buf_valid = function()
        return true
      end,
      win_valid = function()
        return false
      end,
      on = function() end,
      toggle = function() end,
      focus = function() end,
      close = function() end,
    }
  end

  before_each(function()
    original_vim = vim
    spy = require("luassert.spy")

    _G.vim = {
      log = { levels = { ERROR = 3, WARN = 2, INFO = 1, DEBUG = 0 } },
      notify = spy.new(function() end),
      inspect = function(v)
        return tostring(v)
      end,
      schedule = function(fn)
        fn()
      end,
      cmd = function() end,
      split = function(str, sep, _opts)
        local result = {}
        local start = 1
        while true do
          local s, e = string.find(str, sep, start, true)
          if not s then
            table.insert(result, string.sub(str, start))
            break
          end
          table.insert(result, string.sub(str, start, s - 1))
          start = e + 1
        end
        return result
      end,
      tbl_deep_extend = function(_, ...)
        local res = {}
        for _, t in ipairs({ ... }) do
          if type(t) == "table" then
            for k, v in pairs(t) do
              res[k] = v
            end
          end
        end
        return res
      end,
      api = {
        nvim_buf_is_valid = function()
          return true
        end,
        nvim_win_is_valid = function()
          return true
        end,
        nvim_buf_get_option = function()
          return "terminal"
        end,
        nvim_win_call = function(_, fn)
          fn()
        end,
        nvim_get_current_win = function()
          return 1
        end,
        nvim_set_current_win = function() end,
      },
    }

    captured = {}
    mock_snacks = {
      terminal = {
        open = spy.new(function(cmd, opts)
          captured.cmd = cmd
          captured.opts = opts
          return make_term_instance()
        end),
      },
    }

    package.loaded["snacks"] = mock_snacks
    package.loaded["claudecode.logger"] = {
      debug = spy.new(function() end),
      info = spy.new(function() end),
      warn = spy.new(function() end),
      error = spy.new(function() end),
    }
    package.loaded["claudecode.utils"] = {
      normalize_focus = function(focus)
        if focus == nil then
          return true
        end
        return focus
      end,
    }
    package.loaded["claudecode.terminal.snacks"] = nil

    snacks_provider = require("claudecode.terminal.snacks")
  end)

  after_each(function()
    _G.vim = original_vim
    package.loaded["snacks"] = nil
    package.loaded["claudecode.utils"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.terminal.snacks"] = nil
  end)

  local function base_config()
    return { cwd = "/work", split_side = "right", split_width_percentage = 0.30, auto_close = false }
  end

  it("passes a bracketed model alias to Snacks as an argv list, not a shell string", function()
    snacks_provider.open("claude --model opus[1m]", { FOO = "bar" }, base_config(), true)

    assert.spy(mock_snacks.terminal.open).was_called(1)
    assert.is_table(captured.cmd)
    assert.are.same({ "claude", "--model", "opus[1m]" }, captured.cmd)
  end)

  it("wraps an argument-less command in a single-element list", function()
    snacks_provider.open("claude", {}, base_config(), true)

    assert.is_table(captured.cmd)
    assert.are.same({ "claude" }, captured.cmd)
  end)
end)

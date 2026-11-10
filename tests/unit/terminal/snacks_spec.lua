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
      b = setmetatable({}, {
        __index = function()
          return {}
        end,
      }),
      fn = {
        maparg = function()
          return {}
        end,
      },
      keymap = { set = function() end },
      api = {
        nvim_list_bufs = function()
          return {}
        end,
        nvim_buf_call = function(_, fn)
          return fn()
        end,
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
    -- Use the real utils module: snacks.lua calls utils.shell_split, and utils
    -- is pure Lua (safe under the mocked vim).
    package.loaded["claudecode.utils"] = nil
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

  it("keeps quoted arguments intact instead of splitting on inner spaces", function()
    snacks_provider.open("claude --message='hello world'", {}, base_config(), true)

    assert.is_table(captured.cmd)
    assert.are.same({ "claude", "--message=hello world" }, captured.cmd)
  end)

  it("expands a tilde in terminal_cmd before handing argv to Snacks", function()
    local home = os.getenv("HOME")
    snacks_provider.open("~/.claude/local/claude", {}, base_config(), true)

    assert.is_table(captured.cmd)
    assert.are.same({ home .. "/.claude/local/claude" }, captured.cmd)
  end)

  describe("Ctrl-Z in terminal mode (#194)", function()
    local keymap_calls
    local VISIBLE_WIN = 2

    before_each(function()
      keymap_calls = {}
      _G.vim.keymap.set = function(mode, lhs, rhs, opts)
        table.insert(keymap_calls, { mode = mode, lhs = lhs, rhs = rhs, opts = opts })
      end
    end)

    it("maps <C-z> to :suspend on the Claude terminal buffer and on no other buffer", function()
      snacks_provider.open("claude", {}, base_config(), true)

      assert.are.equal(1, #keymap_calls)
      assert.are.equal("t", keymap_calls[1].mode)
      assert.are.equal("<C-z>", keymap_calls[1].lhs)
      assert.are.equal("<Cmd>suspend<CR>", keymap_calls[1].rhs)
      assert.are.equal(1, keymap_calls[1].opts.buffer)
    end)

    it("maps the buffer once: opening the existing terminal again adds no mapping", function()
      mock_snacks.terminal.open = spy.new(function()
        local instance = make_term_instance()
        instance.win = VISIBLE_WIN
        return instance
      end)
      _G.vim.api.nvim_win_get_config = function()
        return {}
      end
      _G.vim.api.nvim_win_get_buf = function()
        return 1
      end

      snacks_provider.open("claude", {}, base_config(), true)
      snacks_provider.open("claude", {}, base_config(), true)

      assert.spy(mock_snacks.terminal.open).was_called(1)
      assert.are.equal(1, #keymap_calls)
    end)

    it("keeps a <C-z> mapping that a FileType or on_buf handler already set on the buffer", function()
      _G.vim.fn.maparg = function()
        return { lhs = "<C-Z>", rhs = "<C-z>", buffer = 1 }
      end

      snacks_provider.open("claude", {}, base_config(), true)

      assert.are.equal(0, #keymap_calls)
    end)
  end)

  -- The buffer filetype goes through the Snacks window options (`bo`), not a later vim.bo write: Snacks applies
  -- `bo` each time it creates the window, so a later write would be undone when Snacks re-creates a closed window.
  describe("buffer filetype", function()
    before_each(function()
      -- The suite's vim mock merges one level deep. These specs need the real recursive merge, because a user's
      -- `bo` table must merge into the default `bo` table.
      local function deep_extend(_, ...)
        local result = {}
        for _, tbl in ipairs({ ... }) do
          for key, value in pairs(tbl) do
            if type(value) == "table" and type(result[key]) == "table" then
              result[key] = deep_extend("force", result[key], value)
            else
              result[key] = value
            end
          end
        end
        return result
      end
      _G.vim.tbl_deep_extend = deep_extend
    end)

    it("defaults the Snacks window filetype to claudecode", function()
      snacks_provider.open("claude", {}, base_config(), true)

      assert.spy(mock_snacks.terminal.open).was_called(1)
      assert.are.equal("claudecode", captured.opts.win.bo.filetype)
    end)

    it("lets snacks_win_opts.bo.filetype override the default", function()
      local config = base_config()
      config.snacks_win_opts = { bo = { filetype = "my_claude" } }

      snacks_provider.open("claude", {}, config, true)

      assert.are.equal("my_claude", captured.opts.win.bo.filetype)
    end)

    it("restores the Snacks terminal filetype when snacks_win_opts names it", function()
      local config = base_config()
      config.snacks_win_opts = { bo = { filetype = "snacks_terminal" } }

      snacks_provider.open("claude", {}, config, true)

      assert.are.equal("snacks_terminal", captured.opts.win.bo.filetype)
    end)

    it("keeps the default filetype when snacks_win_opts sets other buffer options", function()
      local config = base_config()
      config.snacks_win_opts = { bo = { buflisted = false } }

      snacks_provider.open("claude", {}, config, true)

      assert.are.equal("claudecode", captured.opts.win.bo.filetype)
      assert.is_false(captured.opts.win.bo.buflisted)
    end)

    it("keeps the default filetype when snacks_win_opts sets window options only", function()
      local config = base_config()
      config.snacks_win_opts = { position = "float", width = 0.8 }

      snacks_provider.open("claude", {}, config, true)

      assert.are.equal("claudecode", captured.opts.win.bo.filetype)
      assert.are.equal("float", captured.opts.win.position)
    end)
  end)
end)

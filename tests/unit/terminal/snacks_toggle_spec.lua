-- Tests for the Snacks provider hide/show/toggle logic that works around the
-- climbing-cursor bug (#240 split / #183 float).
--
-- The provider keeps Claude's terminal cursor anchor stable by NOT letting Snacks
-- destroy+recreate the window via open_win():
--   * float -> nvim_win_set_config({hide=true/false}) (window kept alive)
--   * split -> close on hide, recreate with vsplit + nvim_win_set_buf on show
-- These tests drive a self-contained Neovim mock that models window config
-- (relative/hide) so the float vs split branching can be asserted without a real
-- Neovim or Snacks.

describe("claudecode.terminal.snacks hide/show/toggle", function()
  local snacks_provider
  local original_vim
  local spy
  local windows -- id -> { buf, config = { relative, hide }, valid }
  local current_win
  local next_win_id
  local next_buf_id
  local mock_snacks
  local open_show_spy

  local function make_window(buf, opts)
    local id = next_win_id
    next_win_id = next_win_id + 1
    windows[id] = {
      buf = buf,
      valid = true,
      config = { relative = (opts and opts.relative) or "", hide = false },
    }
    return id
  end

  -- A Snacks-like terminal instance backed by the mock window registry.
  local function make_term_instance(opts)
    local position = opts and opts.win and opts.win.position or "right"
    local relative = position == "float" and "editor" or ""
    local buf = next_buf_id
    next_buf_id = next_buf_id + 1
    local win = make_window(buf, { relative = relative })
    current_win = win
    local term
    term = {
      buf = buf,
      win = win,
      id = 1,
      opts = { wo = {}, w = {}, position = position },
      buf_valid = function()
        return vim.api.nvim_buf_is_valid(term.buf)
      end,
      win_valid = function()
        return term.win ~= nil and vim.api.nvim_win_is_valid(term.win)
      end,
      on = function() end,
      focus = function() end,
      close = function() end,
      -- Snacks originals that patch_instance captures; show recreates a window.
      hide = function()
        if term.win then
          windows[term.win].valid = false
        end
        term.win = nil
      end,
      show = open_show_spy,
      toggle = function() end,
    }
    return term
  end

  before_each(function()
    original_vim = vim
    spy = require("luassert.spy")
    windows = {}
    current_win = 0
    next_win_id = 1000
    next_buf_id = 1

    open_show_spy = spy.new(function(self)
      -- Snacks re-creates the window from the original opts (e.g. a float).
      local position = self.opts and self.opts.position or "right"
      local relative = position == "float" and "editor" or ""
      self.win = make_window(self.buf, { relative = relative })
      current_win = self.win
      return self
    end)

    _G.vim = {
      log = { levels = { ERROR = 3, WARN = 2, INFO = 1, DEBUG = 0 } },
      notify = spy.new(function() end),
      inspect = function(v)
        return tostring(v)
      end,
      schedule = function(fn)
        fn()
      end,
      o = { columns = 120, lines = 40 },
      w = setmetatable({}, {
        __index = function(t, win)
          rawset(t, win, rawget(t, win) or {})
          return rawget(t, win)
        end,
      }),
      fn = {
        has = function(feature)
          return feature == "nvim-0.10" and 1 or 0
        end,
      },
      cmd = function(c)
        c = tostring(c)
        if c:find("vsplit") then
          local new_id = make_window(nil, { relative = "" })
          current_win = new_id
        end
        -- startinsert / wincmd p / noh: no-ops for these tests
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
      split = function(str, sep)
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
      api = {
        nvim_buf_is_valid = function(b)
          return b ~= nil and b >= 1
        end,
        nvim_buf_get_option = function()
          return "terminal"
        end,
        nvim_win_is_valid = function(w)
          return w ~= nil and windows[w] ~= nil and windows[w].valid
        end,
        nvim_win_get_config = function(w)
          local win = windows[w]
          if not win then
            return {}
          end
          return { relative = win.config.relative, hide = win.config.hide }
        end,
        nvim_win_set_config = function(w, cfg)
          if windows[w] then
            for k, v in pairs(cfg) do
              windows[w].config[k] = v
            end
          end
        end,
        nvim_win_close = function(w)
          if windows[w] then
            windows[w].valid = false
          end
        end,
        nvim_win_get_buf = function(w)
          return windows[w] and windows[w].buf
        end,
        nvim_win_set_buf = function(w, b)
          if windows[w] then
            windows[w].buf = b
          end
        end,
        nvim_win_set_height = function() end,
        nvim_get_current_win = function()
          return current_win
        end,
        nvim_set_current_win = function(w)
          current_win = w
        end,
        nvim_win_call = function(_, fn)
          fn()
        end,
      },
    }

    mock_snacks = {
      terminal = {
        open = spy.new(function(_cmd, opts)
          return make_term_instance(opts)
        end),
      },
      util = { wo = function() end },
    }

    package.loaded["snacks"] = mock_snacks
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function() end,
    }
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

  local function split_config()
    return { cwd = "/w", split_side = "right", split_width_percentage = 0.3, auto_close = false, snacks_win_opts = {} }
  end
  local function float_config()
    return {
      cwd = "/w",
      split_side = "right",
      split_width_percentage = 0.3,
      auto_close = false,
      snacks_win_opts = { position = "float" },
    }
  end

  it("split: simple_toggle hides by closing the window and shows by recreating it", function()
    snacks_provider.open("claude", {}, split_config(), true)
    local term = snacks_provider._get_terminal_for_test()
    assert.is_not_nil(term.win)
    local first_win = term.win
    assert.is_true(windows[first_win].valid)

    -- Hide: window is closed, tracked win cleared.
    snacks_provider.simple_toggle("claude", {}, split_config())
    assert.is_false(windows[first_win].valid)
    assert.is_nil(term.win)

    -- Show: a fresh window is created via vsplit and the buffer is set in it.
    snacks_provider.simple_toggle("claude", {}, split_config())
    assert.is_not_nil(term.win)
    assert.is_true(windows[term.win].valid)
    assert.are.equal(term.buf, windows[term.win].buf)
    -- Snacks' own show() must NOT be used for a split (that path drifts).
    assert.spy(open_show_spy).was_not_called()
  end)

  it("float: simple_toggle config-hides (hide=true) and shows (hide=false) without closing", function()
    snacks_provider.open("claude", {}, float_config(), true)
    local term = snacks_provider._get_terminal_for_test()
    local win = term.win
    assert.are.equal("editor", windows[win].config.relative)

    snacks_provider.simple_toggle("claude", {}, float_config())
    assert.is_true(windows[win].valid) -- window kept alive
    assert.is_true(windows[win].config.hide) -- just parked
    assert.are.equal(win, term.win)

    snacks_provider.simple_toggle("claude", {}, float_config())
    assert.is_false(windows[win].config.hide)
    assert.are.equal(win, term.win)
  end)

  it("treats a config-hidden float as not visible (so a send/open re-shows it)", function()
    snacks_provider.open("claude", {}, float_config(), true)
    local term = snacks_provider._get_terminal_for_test()
    windows[term.win].config.hide = true
    -- get_active_bufnr still reports the buffer (terminal exists, just hidden)...
    assert.are.equal(term.buf, snacks_provider.get_active_bufnr())
    -- ...and a focus toggle un-hides rather than treating it as visible.
    snacks_provider.simple_toggle("claude", {}, float_config())
    assert.is_false(windows[term.win].config.hide)
  end)

  it("split close that errors (E444 last window) does not throw and keeps state sane", function()
    snacks_provider.open("claude", {}, split_config(), true)
    local term = snacks_provider._get_terminal_for_test()
    local win = term.win
    -- Simulate "cannot close last window".
    vim.api.nvim_win_close = function()
      error("E444: Cannot close last window")
    end
    assert.has_no.errors(function()
      snacks_provider.simple_toggle("claude", {}, split_config())
    end)
    -- Close failed, so the window stays and remains tracked (no desync).
    assert.are.equal(win, term.win)
  end)

  it("externally-closed float reopens as a float (via Snacks), not a split", function()
    snacks_provider.open("claude", {}, float_config(), true)
    local term = snacks_provider._get_terminal_for_test()
    -- External close (e.g. :q): window dies but buffer survives; no cc_hide ran.
    windows[term.win].valid = false
    term.win = nil

    snacks_provider.simple_toggle("claude", {}, float_config())
    -- Recreated through Snacks (preserves float opts), NOT the vsplit path.
    assert.spy(open_show_spy).was_called()
    assert.are.equal("editor", windows[term.win].config.relative)
  end)

  it("reuses the existing terminal on a second open() without error", function()
    snacks_provider.open("claude", {}, split_config(), true)
    local term = snacks_provider._get_terminal_for_test()
    local win = term.win
    assert.has_no.errors(function()
      snacks_provider.open("claude", {}, split_config(), true)
    end)
    -- Still the same visible window (no destroy/recreate when already visible).
    assert.are.equal(win, term.win)
    assert.is_true(windows[win].valid)
  end)
end)

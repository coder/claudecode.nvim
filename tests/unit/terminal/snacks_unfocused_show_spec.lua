-- The mock models Snacks: it enters each window it opens unless opts.enter == false, and auto_insert queues
-- `startinsert` on BufEnter of the terminal buffer.

describe("claudecode.terminal.snacks show without focus (#423)", function()
  local snacks_provider
  local original_vim
  local spy
  local windows
  local current_win
  local source_win
  local next_win_id
  local next_buf_id
  local pending_insert
  local bufenter_handlers
  local bufenter_ignored_during_set_buf
  local eventignore_during_set_buf
  local shows
  local mock_snacks

  local function make_window(buf, relative)
    local id = next_win_id
    next_win_id = next_win_id + 1
    windows[id] = { buf = buf, valid = true, config = { relative = relative or "", hide = false } }
    return id
  end

  -- Neovim 0.12: a `-BufEnter` entry un-ignores the event wherever it stands in the list.
  local function ignores_bufenter()
    local ignored = false
    for entry in vim.o.eventignore:gmatch("[^,]+") do
      entry = entry:lower()
      if entry == "-bufenter" then
        return false
      elseif entry == "bufenter" or entry == "all" then
        ignored = true
      end
    end
    return ignored
  end

  local function open_win(term)
    term.win = make_window(term.buf, term.opts.position == "float" and "editor" or "")
    if term.opts.enter ~= false then
      current_win = term.win
      if term.start_insert then
        pending_insert = true
      end
    end
  end

  before_each(function()
    original_vim = vim
    spy = require("luassert.spy")
    windows = {}
    next_win_id = 1000
    next_buf_id = 1
    pending_insert = false
    bufenter_handlers = {}
    bufenter_ignored_during_set_buf = nil
    eventignore_during_set_buf = nil
    shows = {}
    source_win = make_window(500, "")
    current_win = source_win

    _G.vim = {
      log = { levels = { ERROR = 3, WARN = 2, INFO = 1, DEBUG = 0 } },
      notify = spy.new(function() end),
      inspect = function(v)
        return tostring(v)
      end,
      schedule = function(fn)
        fn()
      end,
      o = { columns = 120, lines = 40, eventignore = "" },
      w = setmetatable({}, {
        __index = function(t, win)
          rawset(t, win, rawget(t, win) or {})
          return rawget(t, win)
        end,
      }),
      keymap = { set = function() end },
      fn = {
        maparg = function()
          return {}
        end,
        has = function(feature)
          return feature == "nvim-0.10" and 1 or 0
        end,
      },
      cmd = function(c)
        c = tostring(c)
        if c == "startinsert" then
          pending_insert = true
        elseif c:find("split") then
          current_win = make_window(500, "")
        end
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
        nvim_buf_call = function(_, fn)
          return fn()
        end,
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
          return win and { relative = win.config.relative, hide = win.config.hide } or {}
        end,
        nvim_win_set_config = function(w, cfg)
          for k, v in pairs(cfg) do
            windows[w].config[k] = v
          end
        end,
        nvim_win_close = function(w)
          windows[w].valid = false
        end,
        nvim_win_get_buf = function(w)
          return windows[w] and windows[w].buf
        end,
        nvim_win_set_buf = function(w, b)
          windows[w].buf = b
          bufenter_ignored_during_set_buf = ignores_bufenter()
          eventignore_during_set_buf = vim.o.eventignore
          if bufenter_handlers[b] and not ignores_bufenter() then
            bufenter_handlers[b]()
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
          local buf = next_buf_id
          next_buf_id = next_buf_id + 1
          local term
          term = {
            buf = buf,
            id = 1,
            start_insert = opts.start_insert,
            opts = { wo = {}, w = {}, position = opts.win.position, enter = opts.win.enter },
            buf_valid = function()
              return vim.api.nvim_buf_is_valid(term.buf)
            end,
            on = function() end,
            close = function() end,
            hide = function() end,
            show = function(self)
              table.insert(shows, { enter = self.opts.enter })
              open_win(self)
              return self
            end,
            toggle = function() end,
          }
          open_win(term)
          if opts.auto_insert then
            bufenter_handlers[buf] = function()
              pending_insert = true
            end
          end
          return term
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

  local function config(win_opts, auto_insert)
    return {
      cwd = "/w",
      split_side = "right",
      split_width_percentage = 0.3,
      auto_close = false,
      auto_insert = auto_insert ~= false,
      snacks_win_opts = win_opts or {},
    }
  end

  local function open_then_hide(cfg)
    snacks_provider.open("claude", {}, cfg, true)
    local term = snacks_provider._get_terminal_for_test()
    current_win = source_win
    snacks_provider.simple_toggle("claude", {}, cfg)
    pending_insert = false
    return term
  end

  local function assert_shown_and_caller_untouched(term)
    assert.is_true(vim.api.nvim_win_is_valid(term.win))
    assert.are.equal(term.buf, windows[term.win].buf)
    assert.are.equal(source_win, current_win)
    assert.is_false(pending_insert)
  end

  it("re-showing a hidden split without focus queues no insert and keeps the caller's window", function()
    local cfg = config()
    local term = open_then_hide(cfg)
    assert.is_nil(term.win)

    snacks_provider.open("claude", {}, cfg, false)

    assert_shown_and_caller_untouched(term)
  end)

  it("re-showing a hidden bottom split without focus queues no insert", function()
    local cfg = config({ position = "bottom", height = 0.3 })
    local term = open_then_hide(cfg)

    snacks_provider.open("claude", {}, cfg, false)

    assert_shown_and_caller_untouched(term)
  end)

  it("re-showing a hidden split with focus still enters it and queues the insert", function()
    local cfg = config()
    local term = open_then_hide(cfg)

    snacks_provider.open("claude", {}, cfg, true)

    assert.are.equal(term.win, current_win)
    assert.is_true(pending_insert)
    assert.is_false(bufenter_ignored_during_set_buf)
  end)

  it("re-showing an externally closed float without focus keeps the caller's window and queues no insert", function()
    local cfg = config({ position = "float" })
    snacks_provider.open("claude", {}, cfg, true)
    local term = snacks_provider._get_terminal_for_test()
    windows[term.win].valid = false
    term.win = nil
    current_win = source_win
    pending_insert = false

    snacks_provider.open("claude", {}, cfg, false)

    assert_shown_and_caller_untouched(term)
    assert.are.equal(1, #shows)
    assert.is_false(shows[1].enter)
    assert.is_nil(term.opts.enter)
  end)

  it("re-showing an externally closed float with focus still enters it", function()
    local cfg = config({ position = "float" })
    snacks_provider.open("claude", {}, cfg, true)
    local term = snacks_provider._get_terminal_for_test()
    windows[term.win].valid = false
    term.win = nil
    current_win = source_win

    snacks_provider.open("claude", {}, cfg, true)

    assert.are.equal(term.win, current_win)
    assert.are.equal(1, #shows)
    assert.is_nil(shows[1].enter)
    assert.is_nil(term.opts.enter)
  end)

  it("puts the float's enter option back when Snacks fails to re-show it without focus", function()
    local cfg = config({ position = "float" })
    snacks_provider.open("claude", {}, cfg, true)
    local term = snacks_provider._get_terminal_for_test()
    windows[term.win].valid = false
    term.win = nil
    term._cc.orig_show = function()
      error("E5555: boom")
    end

    assert.has_error(function()
      snacks_provider.open("claude", {}, cfg, false)
    end)

    assert.is_nil(term.opts.enter)
  end)

  it("a user's snacks_win_opts.enter also decides whether a re-created float is entered", function()
    local cfg = config({ position = "float", enter = true })
    snacks_provider.open("claude", {}, cfg, true)
    local term = snacks_provider._get_terminal_for_test()
    windows[term.win].valid = false
    term.win = nil
    current_win = source_win

    snacks_provider.open("claude", {}, cfg, false)

    assert.are.equal(1, #shows)
    assert.is_true(shows[1].enter)
    assert.are.equal(term.win, current_win)
    assert.is_true(term.opts.enter)
  end)

  it("creating the terminal without focus keeps the caller's window and queues no insert", function()
    snacks_provider.open("claude", {}, config(), false)

    local term = snacks_provider._get_terminal_for_test()
    assert_shown_and_caller_untouched(term)
  end)

  it("creating the terminal with focus enters it and queues the insert", function()
    snacks_provider.open("claude", {}, config(), true)

    local term = snacks_provider._get_terminal_for_test()
    assert.are.equal(term.win, current_win)
    assert.is_true(pending_insert)
  end)

  it("a user's snacks_win_opts.enter still decides whether a new terminal is entered", function()
    snacks_provider.open("claude", {}, config({ enter = true }), false)

    local term = snacks_provider._get_terminal_for_test()
    assert.are.equal(term.win, current_win)
    assert.is_true(term.opts.enter)
  end)

  it("a terminal created without focus does not keep enter = false for later shows", function()
    snacks_provider.open("claude", {}, config(), false)

    local term = snacks_provider._get_terminal_for_test()
    assert.is_nil(term.opts.enter)
  end)

  describe("auto_insert of a terminal created without focus", function()
    local function open_options()
      return mock_snacks.terminal.open.calls[1].vals[2]
    end

    it("is on like for a terminal created with focus, and start_insert stays off", function()
      snacks_provider.open("claude", {}, config(), false)

      local term = snacks_provider._get_terminal_for_test()
      assert.is_true(open_options().auto_insert)
      assert.is_false(open_options().start_insert)
      assert.is_false(pending_insert)

      vim.api.nvim_win_set_buf(term.win, term.buf)

      assert.is_true(pending_insert)
    end)

    it("stays off with terminal.auto_insert = false", function()
      snacks_provider.open("claude", {}, config(nil, false), false)

      local term = snacks_provider._get_terminal_for_test()
      assert.is_false(open_options().auto_insert)
      assert.is_false(open_options().start_insert)

      vim.api.nvim_win_set_buf(term.win, term.buf)

      assert.is_false(pending_insert)
    end)

    it("is on, with start_insert, for a terminal created with focus", function()
      snacks_provider.open("claude", {}, config(), true)

      assert.is_true(open_options().auto_insert)
      assert.is_true(open_options().start_insert)
    end)
  end)

  describe("'eventignore'", function()
    it("is back to the caller's value after an unfocused show", function()
      local cfg = config()
      open_then_hide(cfg)
      vim.o.eventignore = "WinEnter"

      snacks_provider.open("claude", {}, cfg, false)

      assert.are.equal("WinEnter", vim.o.eventignore)
    end)

    it("keeps ignoring BufEnter when it already lists other events", function()
      local cfg = config()
      local term = open_then_hide(cfg)
      vim.o.eventignore = "CursorHold"

      snacks_provider.open("claude", {}, cfg, false)

      assert_shown_and_caller_untouched(term)
      assert.are.equal("CursorHold", vim.o.eventignore)
    end)

    local cases = {
      { value = "CursorHold", during = "CursorHold,BufEnter" },
      { value = "all,-BufEnter", during = "all,BufEnter" },
      { value = "-bufenter,CursorHold", during = "CursorHold,BufEnter" },
    }
    for _, case in ipairs(cases) do
      it("holds " .. case.during .. " during the call and comes back to " .. case.value, function()
        local cfg = config()
        local term = open_then_hide(cfg)
        vim.o.eventignore = case.value

        snacks_provider.open("claude", {}, cfg, false)

        assert_shown_and_caller_untouched(term)
        assert.are.equal(case.during, eventignore_during_set_buf)
        assert.are.equal(case.value, vim.o.eventignore)
      end)
    end

    it("is back to the caller's value when the unfocused show fails", function()
      local cfg = config()
      open_then_hide(cfg)
      vim.api.nvim_win_set_buf = function()
        error("E5555: boom")
      end

      assert.has_error(function()
        snacks_provider.open("claude", {}, cfg, false)
      end)

      assert.are.equal("", vim.o.eventignore)
    end)
  end)
end)

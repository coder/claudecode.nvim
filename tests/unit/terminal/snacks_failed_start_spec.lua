-- A failed Snacks start must not leave a window or buffer behind.
--
-- Real Snacks.terminal.open shows its window and scratch buffer first, then calls
-- termopen. For a command that is not executable, termopen raises E475 (or returns
-- -1 when errors are silenced), so the mock below does the same in that order.

describe("claudecode.terminal.snacks failed start", function()
  local snacks_provider
  local original_vim
  local spy
  local windows
  local buffers
  local current_win
  local next_id
  local start_mode
  local original_win
  local opened
  local opened_buf
  local opened_opts
  local debug_lines

  local function new_buf()
    next_id = next_id + 1
    buffers[next_id] = { buftype = "nofile" }
    return next_id
  end

  local function new_win(buf)
    next_id = next_id + 1
    windows[next_id] = { buf = buf }
    current_win = next_id
    return next_id
  end

  local function valid_windows()
    local ids = {}
    for id in pairs(windows) do
      table.insert(ids, id)
    end
    table.sort(ids)
    return ids
  end

  local function snacks_open(cmd, opts)
    local term = {}
    function term:buf_valid()
      return self.buf ~= nil and buffers[self.buf] ~= nil
    end
    function term:on() end
    function term:close(close_opts)
      if self.win and windows[self.win] then
        vim.api.nvim_win_close(self.win, true)
      end
      if (close_opts or {}).buf ~= false and self.buf and buffers[self.buf] then
        vim.api.nvim_buf_delete(self.buf, { force = true })
      end
      self.win = nil
      self.buf = nil
    end

    term.buf = new_buf()
    if opts.win.on_buf then
      opts.win.on_buf(term)
    end
    term.win = new_win(term.buf)
    opened = term
    opened_buf = term.buf
    opened_opts = opts

    if start_mode == "raise" then
      error(
        "...snacks.nvim/lua/snacks/terminal.lua:161: Lua: Vim:E475: Invalid value for argument cmd: '"
          .. cmd[1]
          .. "' is not executable\nstack traceback:\n\t[C]: in function 'jobstart'"
      )
    elseif start_mode == "started" then
      buffers[term.buf].buftype = "terminal"
    end
    return term
  end

  before_each(function()
    original_vim = vim
    spy = require("luassert.spy")
    windows = {}
    buffers = {}
    next_id = 0
    opened = nil
    opened_buf = nil
    opened_opts = nil
    debug_lines = {}
    original_win = new_win(new_buf())
    buffers[windows[original_win].buf].buftype = ""

    _G.vim = {
      log = { levels = { ERROR = 3, WARN = 2, INFO = 1, DEBUG = 0 } },
      notify = spy.new(function() end),
      inspect = require("tests.mocks.vim").inspect,
      tbl_keys = function(t)
        local keys = {}
        for k in pairs(t) do
          table.insert(keys, k)
        end
        return keys
      end,
      tbl_extend = function(_, ...)
        local res = {}
        for _, t in ipairs({ ... }) do
          for k, v in pairs(t) do
            res[k] = v
          end
        end
        return res
      end,
      tbl_deep_extend = function(_, ...)
        local res = {}
        for _, t in ipairs({ ... }) do
          for k, v in pairs(t) do
            res[k] = v
          end
        end
        return res
      end,
      api = {
        nvim_get_current_win = function()
          return current_win
        end,
        nvim_win_is_valid = function(win)
          return win ~= nil and windows[win] ~= nil
        end,
        nvim_buf_is_valid = function(buf)
          return buf ~= nil and buffers[buf] ~= nil
        end,
        nvim_buf_get_option = function(buf, name)
          assert(buffers[buf], "Invalid buffer id: " .. tostring(buf))
          assert(name == "buftype", "unexpected option " .. tostring(name))
          return buffers[buf].buftype
        end,
        nvim_win_close = function(win)
          assert(windows[win], "Invalid window id: " .. tostring(win))
          windows[win] = nil
          if current_win == win then
            current_win = next(windows)
          end
        end,
        nvim_buf_delete = function(buf)
          assert(buffers[buf], "Invalid buffer id: " .. tostring(buf))
          buffers[buf] = nil
        end,
      },
    }

    package.loaded["snacks"] = { terminal = { open = spy.new(snacks_open) } }
    package.loaded["claudecode.logger"] = {
      debug = function(_, ...)
        table.insert(debug_lines, table.concat({ ... }, " "))
      end,
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

  local function config(snacks_win_opts)
    return {
      split_side = "right",
      split_width_percentage = 0.3,
      auto_close = false,
      snacks_win_opts = snacks_win_opts or {},
    }
  end

  local function assert_failed_cleanly()
    assert.are.same({ original_win }, valid_windows())
    assert.are.equal(original_win, current_win)
    assert.is_nil(buffers[opened_buf], "the Snacks scratch buffer must be deleted")
    assert.is_nil(snacks_provider.get_active_bufnr())
    assert.is_nil(snacks_provider._get_terminal_for_test())
    assert.spy(vim.notify).was_called(1)
    assert.are.equal(vim.log.levels.ERROR, vim.notify.calls[1].vals[2])
    return vim.notify.calls[1].vals[1]
  end

  it("closes the window and buffer and notifies once when termopen rejects the command", function()
    start_mode = "raise"

    assert.has_no.errors(function()
      snacks_provider.open("/nonexistent-claude", {}, config(), true)
    end)

    local message = assert_failed_cleanly()
    assert.matches("E475: Invalid value for argument cmd: '/nonexistent%-claude' is not executable", message)
    assert.is_nil(message:find("stack traceback", 1, true))
  end)

  it("treats a start that left no terminal job as a failure", function()
    start_mode = "silenced"

    snacks_provider.open("/nonexistent-claude", {}, config(), true)

    assert_failed_cleanly()
  end)

  it("keeps env values out of the failure notice and debug log", function()
    start_mode = "raise"

    snacks_provider.open("/nonexistent-claude", { SECRET_TEST = "s3cr3t" }, config(), true)

    assert.are.equal("s3cr3t", opened_opts.env.SECRET_TEST)
    local message = assert_failed_cleanly()
    assert.is_nil(message:find("s3cr3t", 1, true))
    assert.are.equal(1, #debug_lines)
    assert.is_nil(debug_lines[1]:find("s3cr3t", 1, true))
    assert.is_not_nil(debug_lines[1]:find("SECRET_TEST", 1, true))
  end)

  it("keeps a started terminal and still runs the user's on_buf", function()
    start_mode = "started"
    local on_buf_arg
    local function user_on_buf(instance)
      on_buf_arg = instance
    end

    snacks_provider.open("claude", {}, config({ on_buf = user_on_buf }), true)

    assert.are.equal(opened.buf, snacks_provider.get_active_bufnr())
    assert.is_not_nil(windows[opened.win])
    assert.are.equal(opened, on_buf_arg)
    assert.spy(vim.notify).was_not_called()
  end)
end)

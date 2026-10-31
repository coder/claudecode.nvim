-- Closing the Snacks terminal ends the Claude job before Snacks wipes the buffer.
-- Deleting a terminal buffer while a write to its job is pending hangs Neovim
-- (neovim/neovim#42508). The mock raises in that case instead of hanging.

describe("claudecode.terminal.snacks close", function()
  local snacks_provider
  local original_vim
  local state
  local logged_errors

  local function fire(event, bufnr)
    for i = #state.autocmds, 1, -1 do
      local autocmd = state.autocmds[i]
      -- A buffer-local autocmd is gone once an earlier handler deleted its buffer.
      local applies = autocmd.buffer == nil or (autocmd.buffer == bufnr and state.buffers[bufnr] ~= nil)
      if autocmd.event == event and applies then
        if autocmd.once then
          table.remove(state.autocmds, i)
        end
        autocmd.callback({ buf = bufnr })
      end
    end
  end

  -- Mirrors Snacks' Win:close, which closes the window and wipes the terminal buffer.
  local function make_term_instance()
    local bufnr = state.next_bufnr
    state.next_bufnr = state.next_bufnr + 1
    local jobid = state.next_jobid
    state.next_jobid = state.next_jobid + 1
    state.buffers[bufnr] = { jobid = jobid }
    state.running_jobs[jobid] = true
    local win = state.next_win
    state.next_win = state.next_win + 1
    state.windows[win] = { buf = bufnr }
    local term = { buf = bufnr, win = win, opts = { wo = {}, w = {} } }
    function term:buf_valid()
      return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
    end
    function term:win_valid()
      return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
    end
    function term:on(event, callback)
      table.insert(state.autocmds, { event = event, buffer = self.buf, callback = callback })
    end
    function term:close()
      local close_win, close_buf = self.win, self.buf
      self.win, self.buf = nil, nil
      if close_win and vim.api.nvim_win_is_valid(close_win) then
        vim.api.nvim_win_close(close_win, true)
      end
      if close_buf and vim.api.nvim_buf_is_valid(close_buf) then
        vim.api.nvim_buf_delete(close_buf, { force = true })
      end
    end
    return term
  end

  before_each(function()
    original_vim = vim
    logged_errors = {}
    state = {
      buffers = {},
      windows = {},
      autocmds = {},
      running_jobs = {},
      exiting_jobs = {},
      pending_writes = {},
      next_bufnr = 1,
      next_jobid = 7,
      next_win = 1000,
      waited_ms = 0,
    }

    _G.vim = {
      log = { levels = { ERROR = 3, WARN = 2, INFO = 1, DEBUG = 0 } },
      notify = function() end,
      schedule = function(fn)
        fn()
      end,
      cmd = setmetatable({ checktime = function() end }, {
        __call = function() end,
      }),
      o = { columns = 120, lines = 40 },
      v = { event = { status = 129 } },
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
      bo = setmetatable({}, {
        __index = function(_, bufnr)
          local buf = state.buffers[bufnr]
          return { channel = buf and buf.jobid or 0, buftype = "terminal" }
        end,
      }),
      fn = {
        has = function(feature)
          return feature == "nvim-0.10" and 1 or 0
        end,
        chansend = function(id, data)
          state.pending_writes[id] = true
          return #data
        end,
        jobwait = function(ids)
          local results = {}
          for i, id in ipairs(ids) do
            results[i] = state.running_jobs[id] and -1 or -3
          end
          return results
        end,
        jobstop = function(id)
          if not state.running_jobs[id] then
            return 0
          end
          state.running_jobs[id] = nil
          table.insert(state.exiting_jobs, id)
          return 1
        end,
      },
      -- A stopped job exits only when the event loop runs. Its pending writes end first, then TermClose fires.
      wait = function(timeout, condition)
        local exiting = state.exiting_jobs
        state.exiting_jobs = {}
        for _, id in ipairs(exiting) do
          state.pending_writes[id] = nil
          for bufnr, buf in pairs(state.buffers) do
            if buf.jobid == id then
              fire("TermClose", bufnr)
            end
          end
        end
        if condition() then
          return true
        end
        state.waited_ms = state.waited_ms + timeout
        return false
      end,
      api = {
        nvim_buf_is_valid = function(bufnr)
          return state.buffers[bufnr] ~= nil
        end,
        nvim_buf_get_option = function()
          return "terminal"
        end,
        nvim_buf_delete = function(bufnr)
          local buf = state.buffers[bufnr]
          assert(buf, "nvim_buf_delete: invalid buffer " .. tostring(bufnr))
          if state.pending_writes[buf.jobid] then
            error("Neovim hangs: terminal buffer deleted with a pending write (neovim/neovim#42508)")
          end
          fire("BufWipeout", bufnr)
          for win, w in pairs(state.windows) do
            if w.buf == bufnr then
              state.windows[win] = nil
            end
          end
          state.buffers[bufnr] = nil
          state.running_jobs[buf.jobid] = nil
        end,
        nvim_create_autocmd = function(event, opts)
          table.insert(state.autocmds, {
            event = event,
            buffer = opts.buffer,
            once = opts.once,
            callback = opts.callback,
          })
        end,
        nvim_win_is_valid = function(win)
          return state.windows[win] ~= nil
        end,
        nvim_win_close = function(win)
          state.windows[win] = nil
        end,
        nvim_win_get_buf = function(win)
          return state.windows[win] and state.windows[win].buf
        end,
        nvim_win_get_config = function()
          return { relative = "" }
        end,
        nvim_get_current_win = function()
          return 1
        end,
        nvim_set_current_win = function() end,
        nvim_win_call = function(_, fn)
          fn()
        end,
      },
    }

    package.loaded["snacks"] = {
      terminal = {
        open = function()
          return make_term_instance()
        end,
      },
    }
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function(_, message)
        table.insert(logged_errors, message)
      end,
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

  local function open_claude(auto_close)
    snacks_provider.open("claude", {}, { cwd = "/w", split_side = "right", auto_close = auto_close }, true)
    local bufnr = snacks_provider.get_active_bufnr()
    assert.is_not_nil(bufnr)
    return bufnr, state.buffers[bufnr].jobid
  end

  for _, auto_close in ipairs({ false, true }) do
    it(("stops Claude quietly when closed right after a send, auto_close=%s"):format(auto_close), function()
      local bufnr, jobid = open_claude(auto_close)
      vim.fn.chansend(jobid, "hello\r")

      snacks_provider.close()

      assert.is_nil(state.running_jobs[jobid])
      assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
      assert.is_nil(next(state.windows))
      assert.is_nil(snacks_provider.get_active_bufnr())
      assert.are.same({}, logged_errors)
    end)
  end

  it("reports an error when Claude exits with a failure on its own", function()
    local bufnr, jobid = open_claude(true)
    state.running_jobs[jobid] = nil
    vim.v.event.status = 1

    fire("TermClose", bufnr)

    assert.are.equal(1, #logged_errors)
    assert.truthy(logged_errors[1]:find("exited with code 1", 1, true))
  end)

  it("closes the buffer of an exited Claude without waiting out the timeout", function()
    local bufnr, jobid = open_claude(false)
    state.running_jobs[jobid] = nil

    snacks_provider.close()

    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    assert.are.equal(0, state.waited_ms)
  end)

  it("keeps Claude running when the terminal is only hidden", function()
    local bufnr, jobid = open_claude(false)

    snacks_provider.simple_toggle("claude", {}, { cwd = "/w", split_side = "right", auto_close = false })

    assert.is_nil(next(state.windows))
    assert.is_true(state.running_jobs[jobid])
    assert.are.equal(bufnr, snacks_provider.get_active_bufnr())
  end)
end)

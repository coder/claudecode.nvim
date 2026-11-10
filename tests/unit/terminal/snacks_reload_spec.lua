-- After a reload of the plugin's modules (:Lazy reload), the snacks provider must find the Claude that its earlier
-- copy started, and must stop a Claude that the native provider started. The reloaded copy tracks nothing, but
-- Snacks keeps its terminal instances and the Claude buffer keeps its mark.

describe("claudecode.terminal.snacks after a module reload", function()
  local snacks_provider
  local original_vim
  local state
  local started -- every Snacks.terminal.open call
  local notices -- every vim.notify call
  local logged_errors
  local config = { cwd = "/w", split_side = "right", split_width_percentage = 0.3, auto_close = true }

  local function windows_showing(bufnr)
    local count = 0
    for _, w in pairs(state.windows) do
      if w.buf == bufnr then
        count = count + 1
      end
    end
    return count
  end

  local function running_count()
    local count = 0
    for _ in pairs(state.running_jobs) do
      count = count + 1
    end
    return count
  end

  local function new_window(bufnr)
    local win = state.next_win
    state.next_win = state.next_win + 1
    state.windows[win] = { buf = bufnr }
    state.current_win = win
    return win
  end

  -- Mirrors Snacks.terminal.open: it creates the instance, shows its window, then starts the job.
  local function snacks_open(_, opts)
    local bufnr = state.next_bufnr
    state.next_bufnr = state.next_bufnr + 1
    local jobid = state.next_jobid
    state.next_jobid = state.next_jobid + 1
    state.buffers[bufnr] = { jobid = jobid, vars = {} }
    state.running_jobs[jobid] = true
    local term = { buf = bufnr, opts = { wo = {}, w = {} } }
    function term:buf_valid()
      return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
    end
    -- The provider's TermClose handler, called when the job exits.
    function term:on(event, callback)
      if event == "TermClose" then
        state.buffers[self.buf].snacks_term_close = callback
      end
    end
    function term:close()
      local win, buf = self.win, self.buf
      self.win, self.buf = nil, nil
      if win and state.windows[win] then
        state.windows[win] = nil
      end
      if buf and state.buffers[buf] then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    term.hide, term.show, term.toggle = function() end, function() end, function() end
    if opts.win.on_buf then
      opts.win.on_buf(term)
    end
    term.win = new_window(bufnr)
    table.insert(state.terminals, term)
    table.insert(started, term)
    return term
  end

  local function reload_snacks()
    package.loaded["claudecode.terminal.snacks"] = nil
    package.loaded["claudecode.terminal.owned"] = nil
    snacks_provider = require("claudecode.terminal.snacks")
  end

  before_each(function()
    original_vim = vim
    started = {}
    notices = {}
    logged_errors = {}
    state = {
      buffers = {},
      windows = {},
      terminals = {},
      running_jobs = {},
      exiting_jobs = {},
      scheduled = {},
      term_close_autocmds = {},
      next_bufnr = 1,
      next_jobid = 7,
      next_win = 1000,
      current_win = 1,
    }

    _G.vim = {
      log = { levels = { ERROR = 3, WARN = 2, INFO = 1, DEBUG = 0 } },
      notify = function(message, level)
        table.insert(notices, { message = message, level = level })
      end,
      schedule = function(fn)
        table.insert(state.scheduled, fn)
      end,
      cmd = setmetatable({ checktime = function() end }, {
        __call = function(_, command)
          if tostring(command):find("vsplit") then
            new_window(nil)
          end
        end,
      }),
      o = { columns = 120, lines = 40 },
      v = { event = { status = 0 } },
      w = setmetatable({}, {
        __index = function(t, win)
          rawset(t, win, {})
          return rawget(t, win)
        end,
      }),
      b = setmetatable({}, {
        __index = function(_, bufnr)
          assert(state.buffers[bufnr], "invalid buffer " .. tostring(bufnr))
          return state.buffers[bufnr].vars
        end,
      }),
      bo = setmetatable({}, {
        __index = function(_, bufnr)
          local buf = state.buffers[bufnr]
          return { channel = buf and buf.jobid or 0, buftype = "terminal" }
        end,
      }),
      tbl_deep_extend = function(_, ...)
        local res = {}
        for _, t in ipairs({ ... }) do
          for k, v in pairs(t) do
            res[k] = v
          end
        end
        return res
      end,
      keymap = { set = function() end },
      fn = {
        has = function(feature)
          return feature == "nvim-0.10" and 1 or 0
        end,
        maparg = function()
          return {}
        end,
        -- Neovim raises for a job that exited or was stopped.
        jobpid = function(id)
          if not state.running_jobs[id] then
            error("Vim:E900: Invalid channel id")
          end
          return 40000 + id
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
      -- vim.wait runs the event loop: a stopped job exits and fires TermClose, and scheduled callbacks run.
      wait = function(_, condition)
        local exiting = state.exiting_jobs
        state.exiting_jobs = {}
        for _, id in ipairs(exiting) do
          for bufnr, buf in pairs(state.buffers) do
            if buf.jobid == id then
              for _, autocmd in ipairs(buf.term_close_autocmds or {}) do
                autocmd.callback({ buf = bufnr })
              end
            end
            if buf.jobid == id and buf.snacks_term_close then
              buf.snacks_term_close()
            end
            if buf.jobid == id then
              for _, callback in ipairs(state.term_close_autocmds) do
                callback({ buf = bufnr })
              end
            end
          end
        end
        while #state.scheduled > 0 do
          table.remove(state.scheduled, 1)()
        end
        return condition()
      end,
      api = {
        nvim_buf_is_valid = function(bufnr)
          return state.buffers[bufnr] ~= nil
        end,
        nvim_buf_get_option = function()
          return "terminal"
        end,
        nvim_list_bufs = function()
          local bufs = {}
          for bufnr in pairs(state.buffers) do
            table.insert(bufs, bufnr)
          end
          table.sort(bufs)
          return bufs
        end,
        nvim_buf_delete = function(bufnr)
          assert(state.buffers[bufnr], "nvim_buf_delete: invalid buffer " .. tostring(bufnr))
          local jobid = state.buffers[bufnr].jobid
          for win, w in pairs(state.windows) do
            if w.buf == bufnr then
              state.windows[win] = nil
            end
          end
          state.buffers[bufnr] = nil
          state.running_jobs[jobid] = nil
        end,
        nvim_create_autocmd = function(event, opts)
          if event == "TermClose" and opts.buffer and state.buffers[opts.buffer] then
            local buf = state.buffers[opts.buffer]
            buf.term_close_autocmds = buf.term_close_autocmds or {}
            table.insert(buf.term_close_autocmds, opts)
          elseif event == "TermClose" and not opts.buffer then
            table.insert(state.term_close_autocmds, opts.callback)
          end
        end,
        nvim_create_augroup = function(name)
          return name
        end,
        nvim_clear_autocmds = function(opts)
          local buf = state.buffers[opts.buffer]
          if not buf then
            return
          end
          local kept = {}
          for _, autocmd in ipairs(buf.term_close_autocmds or {}) do
            if autocmd.group ~= opts.group then
              table.insert(kept, autocmd)
            end
          end
          buf.term_close_autocmds = kept
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
        nvim_win_set_buf = function(win, bufnr)
          state.windows[win].buf = bufnr
        end,
        nvim_win_set_height = function() end,
        nvim_win_get_config = function()
          return { relative = "" }
        end,
        nvim_get_current_win = function()
          return state.current_win
        end,
        nvim_set_current_win = function(win)
          state.current_win = win
        end,
        nvim_win_call = function(_, fn)
          fn()
        end,
        nvim_buf_call = function(_, fn)
          return fn()
        end,
      },
    }

    package.loaded["snacks"] = {
      terminal = {
        open = snacks_open,
        list = function()
          local list = {}
          for _, term in ipairs(state.terminals) do
            if term:buf_valid() then
              table.insert(list, term)
            end
          end
          return list
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
    reload_snacks()
  end)

  after_each(function()
    _G.vim = original_vim
    package.loaded["snacks"] = nil
    package.loaded["claudecode.utils"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.terminal.snacks"] = nil
    package.loaded["claudecode.terminal.owned"] = nil
    package.loaded["claudecode.terminal.native"] = nil
    package.preload["claudecode.terminal.native"] = nil
    package.preload["claudecode.terminal.snacks"] = nil
  end)

  local entries = {
    {
      "open",
      function()
        snacks_provider.open("claude", {}, config, true)
      end,
    },
    {
      "simple_toggle",
      function()
        snacks_provider.simple_toggle("claude", {}, config)
      end,
    },
    {
      "focus_toggle",
      function()
        snacks_provider.focus_toggle("claude", {}, config)
      end,
    },
  }

  for _, hidden in ipairs({ false, true }) do
    it("finds the running Claude instead of starting a second one (hidden=" .. tostring(hidden) .. ")", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      if hidden then
        snacks_provider.simple_toggle("claude", {}, config)
        assert.are.equal(0, windows_showing(claude.buf))
      end
      reload_snacks()

      snacks_provider.open("claude", {}, config, true)

      assert.are.equal(1, #started)
      assert.are.equal(1, running_count())
      assert.are.equal(claude, snacks_provider._get_terminal_for_test())
      assert.are.equal(1, windows_showing(claude.buf))
    end)
  end

  for _, entry in ipairs(entries) do
    local entry_name, start = entry[1], entry[2]
    it("starts no second Claude when " .. entry_name .. " runs and Claude is hidden", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      snacks_provider.simple_toggle("claude", {}, config)
      reload_snacks()

      start()

      assert.are.equal(1, #started)
      assert.are.equal(1, running_count())
      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
    end)
  end

  -- A toggle treats the adopted terminal as it treats a tracked one: it hides a visible terminal.
  for _, entry in ipairs({ entries[2], entries[3] }) do
    local entry_name, toggle = entry[1], entry[2]
    it("hides the running Claude when " .. entry_name .. " runs and Claude is visible", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      reload_snacks()

      toggle()

      assert.are.equal(1, #started)
      assert.are.equal(1, running_count())
      assert.are.equal(0, windows_showing(claude.buf))
    end)
  end

  for _, hidden in ipairs({ false, true }) do
    it("stops the running Claude when close runs (hidden=" .. tostring(hidden) .. ")", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      local claude_bufnr, claude_jobid = claude.buf, state.buffers[claude.buf].jobid
      if hidden then
        snacks_provider.simple_toggle("claude", {}, config)
      end
      reload_snacks()

      snacks_provider.close()

      assert.is_nil(state.running_jobs[claude_jobid])
      assert.is_false(vim.api.nvim_buf_is_valid(claude_bufnr))
      assert.is_nil(snacks_provider.get_active_bufnr())
    end)
  end

  for _, hidden in ipairs({ false, true }) do
    it("reports the terminal as active before any command runs (hidden=" .. tostring(hidden) .. ")", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      if hidden then
        snacks_provider.simple_toggle("claude", {}, config)
      end
      reload_snacks()

      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
    end)
  end

  it("keeps the tracked terminal when another marked terminal is listed first", function()
    snacks_provider.open("claude", {}, config, true)
    local claude = started[1]
    reload_snacks()
    snacks_provider.open("claude", {}, config, true)
    assert.are.equal(claude, snacks_provider._get_terminal_for_test())
    -- Snacks lists a second marked terminal before the tracked one.
    local other = snacks_open("claude", { win = {} })
    state.buffers[other.buf].vars.claudecode_snacks_terminal = true
    state.terminals[#state.terminals] = nil
    table.insert(state.terminals, 1, other)

    assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
    assert.are.equal(claude, snacks_provider._get_terminal_for_test())
  end)

  -- A job that a stop kills exits with an error status. The provider reports such an exit, except when another
  -- provider stopped the Claude on purpose.
  describe("the exit status of a Claude that stops", function()
    before_each(function()
      vim.v.event.status = 129
    end)

    it("is reported as an error when Claude exits on its own", function()
      snacks_provider.open("claude", {}, config, true)
      local claude_bufnr = started[1].buf
      state.running_jobs[state.buffers[claude_bufnr].jobid] = nil

      state.buffers[claude_bufnr].snacks_term_close()

      assert.are.equal(1, #logged_errors)
      assert.truthy(logged_errors[1]:find("exited with code 129", 1, true))
    end)

    -- Snacks sets the buffer of an instance to nil when it closes. The job exits and fires TermClose after that.
    it("raises no Lua error when the instance closed before the job exited", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      local on_term_close = state.buffers[claude.buf].snacks_term_close

      claude:close()

      assert.has_no.errors(on_term_close)
      assert.are.equal(1, #logged_errors)
      assert.truthy(logged_errors[1]:find("exited with code 129", 1, true))
    end)

    it("is not reported when the native provider stops the Claude directly", function()
      snacks_provider.open("claude", {}, config, true)
      local claude_bufnr = started[1].buf
      local claude_jobid = state.buffers[claude_bufnr].jobid
      package.loaded["claudecode.terminal.snacks"] = nil
      package.preload["claudecode.terminal.snacks"] = function()
        error("module 'claudecode.terminal.snacks' cannot load")
      end
      local owned = require("claudecode.terminal.owned")

      assert.is_true(owned.stop_other(owned.SNACKS_MARK, "snacks"))

      assert.is_nil(state.running_jobs[claude_jobid])
      assert.is_false(vim.api.nvim_buf_is_valid(claude_bufnr))
      assert.are.same({}, logged_errors)
    end)
  end)

  -- The job exits: Snacks' TermClose handler of the copy that started the Claude runs first, then the handlers that
  -- later copies added. The scheduled close that the first handler queues has not run.
  local function exit_job(bufnr)
    local buf = state.buffers[bufnr]
    state.running_jobs[buf.jobid] = nil
    if buf.snacks_term_close then
      buf.snacks_term_close()
    end
    for _, autocmd in ipairs(buf.term_close_autocmds or {}) do
      autocmd.callback({ buf = bufnr })
    end
  end

  describe("a Claude that exits between its TermClose and the scheduled close", function()
    for _, entry in ipairs(entries) do
      for _, hidden in ipairs({ false, true }) do
        it(string.format("is not shown again by %s after a reload (hidden=%s)", entry[1], tostring(hidden)), function()
          snacks_provider.open("claude", {}, config, true)
          local claude = started[1]
          if hidden then
            snacks_provider.simple_toggle("claude", {}, config)
          end
          reload_snacks()
          assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())

          exit_job(claude.buf)
          entry[2]()

          assert.are.equal(2, #started)
          assert.are.equal(1, running_count())
          assert.are.equal(1, windows_showing(started[2].buf))
          assert.are.equal(started[2], snacks_provider._get_terminal_for_test())
        end)
      end
    end

    -- :ClaudeCodeClose clears `terminal` before it waits. A scheduled open can start another Claude in that wait,
    -- before the stopped job's TermClose runs.
    it("does not forget a newer terminal that an open started while the adopted one closed", function()
      snacks_provider.open("claude", {}, config, true)
      reload_snacks()
      assert.are.equal(started[1].buf, snacks_provider.get_active_bufnr())
      local wait = vim.wait
      vim.wait = function(...)
        while #state.scheduled > 0 do
          table.remove(state.scheduled, 1)()
        end
        return wait(...)
      end
      vim.schedule(function()
        snacks_provider.open("claude", {}, config, true)
      end)

      snacks_provider.close()

      assert.are.equal(2, #started)
      assert.are.equal(started[2], snacks_provider._get_terminal_for_test())
    end)

    it("keeps one handler per buffer, however many reloads adopt it", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      for _ = 1, 3 do
        reload_snacks()
        assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
      end

      assert.are.equal(1, #state.buffers[claude.buf].term_close_autocmds)
    end)

    it("stays tracked without auto_close, which keeps an exited Claude by design", function()
      snacks_provider.open("claude", {}, { cwd = "/w", split_side = "right", auto_close = false }, true)
      local claude = started[1]
      reload_snacks()
      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())

      exit_job(claude.buf)

      assert.are.equal(claude, snacks_provider._get_terminal_for_test())
      assert.are.equal(0, #(state.buffers[claude.buf].term_close_autocmds or {}))
    end)
  end)

  it("starts a new Claude when the earlier one exited", function()
    snacks_provider.open("claude", {}, { cwd = "/w", split_side = "right", auto_close = false }, true)
    state.running_jobs[state.buffers[started[1].buf].jobid] = nil
    reload_snacks()

    snacks_provider.open("claude", {}, config, true)

    assert.are.equal(2, #started)
  end)

  describe("a Claude that the native provider started", function()
    local native_bufnr, native_jobid = 50, 5000
    local native_closed, native_available

    before_each(function()
      native_closed = 0
      native_available = true
      state.buffers[native_bufnr] = { jobid = native_jobid, vars = { claudecode_native_terminal = true } }
      state.windows[500] = { buf = native_bufnr }
      state.running_jobs[native_jobid] = true
      -- The native provider stops its own Claude and deletes the buffer.
      package.loaded["claudecode.terminal.native"] = {
        is_available = function()
          return native_available
        end,
        close = function()
          native_closed = native_closed + 1
          state.running_jobs[native_jobid] = nil
          state.buffers[native_bufnr] = nil
          state.windows[500] = nil
        end,
      }
    end)

    for _, entry in ipairs(entries) do
      local entry_name, start = entry[1], entry[2]
      it("is stopped before the snacks provider starts its own when " .. entry_name .. " runs", function()
        start()

        assert.are.equal(1, native_closed)
        assert.are.equal(1, #notices)
        assert.are.equal(vim.log.levels.WARN, notices[1].level)
        assert.is_nil(state.running_jobs[native_jobid])
        assert.are.equal(1, #started)
        assert.are.equal(1, running_count())
      end)
    end

    it("is stopped when close runs and the snacks provider tracks no terminal", function()
      snacks_provider.close()

      assert.are.equal(1, native_closed)
      assert.are.equal(1, #notices)
      assert.are.equal(vim.log.levels.WARN, notices[1].level)
      assert.is_nil(state.running_jobs[native_jobid])
    end)

    -- The native provider cannot stop a Claude that it cannot find or load. The snacks provider stops the marked
    -- buffer itself.
    local function assert_stopped_directly()
      assert.is_nil(state.running_jobs[native_jobid])
      assert.is_nil(state.buffers[native_bufnr])
      assert.are.equal(1, #notices)
      assert.are.equal(vim.log.levels.WARN, notices[1].level)
    end

    it("is stopped directly when the native provider is not available", function()
      native_available = false

      snacks_provider.open("claude", {}, config, true)

      assert.are.equal(0, native_closed)
      assert_stopped_directly()
      assert.are.equal(1, #started)
      assert.are.equal(1, running_count())
    end)

    it("is stopped directly when the native provider cannot load", function()
      package.loaded["claudecode.terminal.native"] = nil
      package.preload["claudecode.terminal.native"] = function()
        error("module 'claudecode.terminal.native' cannot load")
      end

      snacks_provider.open("claude", {}, config, true)

      assert_stopped_directly()
      assert.are.equal(1, #started)
      assert.are.equal(1, running_count())
    end)

    it("is stopped directly when the native provider finds no terminal to stop", function()
      package.loaded["claudecode.terminal.native"].close = function()
        native_closed = native_closed + 1
      end

      snacks_provider.close()

      assert.are.equal(1, native_closed)
      assert_stopped_directly()
    end)

    it("is not reported as stopped when its buffer survives the stop", function()
      native_available = false
      local delete = vim.api.nvim_buf_delete
      vim.api.nvim_buf_delete = function(bufnr)
        if bufnr ~= native_bufnr then
          delete(bufnr)
        end
      end

      snacks_provider.close()

      assert.is_not_nil(state.buffers[native_bufnr])
      assert.are.same({}, notices)
      assert.are.same({ "Could not stop the Claude that the native provider started." }, logged_errors)
    end)

    -- Stopping a Claude waits for its job to exit, which runs scheduled callbacks and TermClose autocmds. An open()
    -- among them starts Claude, and the open that started the stop must not start another.
    it("does not start a second Claude when an open runs while the native provider stops its Claude", function()
      local close = package.loaded["claudecode.terminal.native"].close
      package.loaded["claudecode.terminal.native"].close = function()
        close()
        snacks_provider.open("claude", {}, config, true)
      end

      snacks_provider.open("claude", {}, config, true)

      assert.are.equal(1, #started)
      assert.are.equal(1, running_count())
      assert.are.equal(started[1], snacks_provider._get_terminal_for_test())
    end)

    it("does not start a second Claude when a TermClose autocmd opens while the stop waits", function()
      native_available = false
      local opened = false
      table.insert(state.term_close_autocmds, function()
        if not opened then
          opened = true
          snacks_provider.open("claude", {}, config, true)
        end
      end)

      snacks_provider.open("claude", {}, config, true)

      assert.is_true(opened)
      assert.are.equal(1, #started)
      assert.are.equal(1, running_count())
    end)

    it("is left alone when the snacks provider finds its own terminal", function()
      -- The snacks Claude starts while no native Claude runs. The native Claude appears after the reload.
      state.buffers[native_bufnr].vars.claudecode_native_terminal = nil
      snacks_provider.open("claude", {}, config, true)
      reload_snacks()
      state.buffers[native_bufnr].vars.claudecode_native_terminal = true

      snacks_provider.open("claude", {}, config, true)

      assert.are.equal(0, native_closed)
      assert.are.equal(1, #started)
    end)
  end)
end)

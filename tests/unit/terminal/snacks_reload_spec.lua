-- After a reload of the plugin's modules (:Lazy reload), the snacks provider must find the Claude that its earlier
-- copy started, and must stop a Claude that the native provider started. The reloaded copy tracks nothing, but
-- Snacks keeps its terminal instances and the Claude buffer keeps its mark.

describe("claudecode.terminal.snacks after a module reload", function()
  local snacks_provider
  local original_vim
  local state
  local started -- every Snacks.terminal.open call
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
    function term:on() end
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
    state = {
      buffers = {},
      windows = {},
      terminals = {},
      running_jobs = {},
      exiting_jobs = {},
      scheduled = {},
      next_bufnr = 1,
      next_jobid = 7,
      next_win = 1000,
      current_win = 1,
    }

    _G.vim = {
      log = { levels = { ERROR = 3, WARN = 2, INFO = 1, DEBUG = 0 } },
      notify = function() end,
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
      fn = {
        has = function(feature)
          return feature == "nvim-0.10" and 1 or 0
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
            if buf.jobid == id and buf.on_term_close then
              buf.on_term_close({ buf = bufnr })
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
            state.buffers[opts.buffer].on_term_close = opts.callback
          end
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
      error = function() end,
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

  it("starts a new Claude when the earlier one exited", function()
    snacks_provider.open("claude", {}, { cwd = "/w", split_side = "right", auto_close = false }, true)
    state.running_jobs[state.buffers[started[1].buf].jobid] = nil
    reload_snacks()

    snacks_provider.open("claude", {}, config, true)

    assert.are.equal(2, #started)
  end)

  describe("a Claude that the native provider started", function()
    local native_bufnr, native_jobid = 50, 5000
    local native_closed

    before_each(function()
      native_closed = 0
      state.buffers[native_bufnr] = { jobid = native_jobid, vars = { claudecode_native_terminal = true } }
      state.windows[500] = { buf = native_bufnr }
      state.running_jobs[native_jobid] = true
      -- The native provider stops its own Claude and deletes the buffer.
      package.loaded["claudecode.terminal.native"] = {
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
        assert.is_nil(state.running_jobs[native_jobid])
        assert.are.equal(1, #started)
        assert.are.equal(1, running_count())
      end)
    end

    it("is stopped when close runs and the snacks provider tracks no terminal", function()
      snacks_provider.close()

      assert.are.equal(1, native_closed)
      assert.is_nil(state.running_jobs[native_jobid])
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

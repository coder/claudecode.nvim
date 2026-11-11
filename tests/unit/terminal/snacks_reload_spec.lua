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
    state.windows[win] = { buf = bufnr, tab = state.current_tab }
    state.current_win = win
    return win
  end

  -- Snacks.terminal.tid: the key of an instance is its command, directory, env and count.
  local function snacks_key(cmd, opts)
    local env = {}
    for name, value in pairs(opts.env or {}) do
      table.insert(env, name .. "=" .. tostring(value))
    end
    table.sort(env)
    local command = type(cmd) == "table" and table.concat(cmd, "\0") or tostring(cmd)
    return table.concat({ command, tostring(opts.cwd), table.concat(env, "\0"), tostring(opts.count or 1) }, "\1")
  end

  -- Mirrors Snacks.terminal.open: it creates the instance, shows its window, then starts the job. It keeps the
  -- instance under its key, and Snacks clears that key when the buffer is wiped, whichever instance holds it by then.
  local function snacks_open(cmd, opts)
    local bufnr = state.next_bufnr
    state.next_bufnr = state.next_bufnr + 1
    local jobid = state.next_jobid
    state.next_jobid = state.next_jobid + 1
    local key = snacks_key(cmd, opts)
    state.buffers[bufnr] = { jobid = jobid, vars = {}, key = key }
    state.running_jobs[jobid] = true
    local win_opts = opts.win or {}
    local term = {
      buf = bufnr,
      key = key,
      opts = {
        wo = {},
        w = {},
        position = win_opts.position,
        width = win_opts.width,
        relative = win_opts.relative,
        win = win_opts.win,
        -- What Snacks resolves too: the keys, the callbacks and the buffer options. A buffer variable cannot keep them.
        bo = win_opts.bo or { filetype = "snacks_terminal" },
        keys = win_opts.keys,
        on_buf = win_opts.on_buf,
        on_win = function() end,
      },
    }
    state.keyed[key] = term
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
    -- Snacks maps the keys of an instance to the buffer when it shows the window, and each map calls `self:hide()` on
    -- that instance.
    -- Win:show registered these at the first show of the instance.
    term.id, term.events = bufnr, { { event = "WinClosed" } }
    function term:_on() end
    function term:fixbuf() end
    state.buffers[bufnr].mapped_by = term
    state.buffers[bufnr].mapped_keys = {}
    for name, spec in pairs(opts.win.keys or {}) do
      state.buffers[bufnr].mapped_keys[name] = spec
    end
    if opts.win.on_buf then
      opts.win.on_buf(term)
    end
    term.win = new_window(bufnr)
    -- Snacks marks every window that it shows.
    vim.w[term.win].snacks_win = { id = 1 }
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
      wrapped = {}, -- every Snacks.win call
      events_registered = {}, -- every Snacks.win:_on call
      autocmds = {}, -- every BufWinEnter autocmd
      keyed = {},
      running_jobs = {},
      exiting_jobs = {},
      scheduled = {},
      term_close_autocmds = {},
      next_bufnr = 1,
      next_jobid = 7,
      next_win = 1000,
      current_win = 1,
      current_tab = 1,
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
          -- Neovim raises for a buffer that is not valid, and for a name that is not a number.
          local buf = state.buffers[bufnr]
          assert(buf, "Invalid buffer id: " .. tostring(bufnr))
          return { channel = buf.jobid, buftype = "terminal", filetype = buf.filetype }
        end,
      }),
      tbl_deep_extend = function(_, ...)
        local function merge(into, from)
          for k, v in pairs(from) do
            if type(v) == "table" and type(into[k]) == "table" and v[1] == nil then
              into[k] = merge(vim.tbl_deep_extend("force", into[k]), v)
            else
              into[k] = v
            end
          end
          return into
        end
        local res = {}
        for _, t in ipairs({ ... }) do
          merge(res, t)
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
        -- The windows that show a buffer.
        win_findbuf = function(bufnr)
          local wins = {}
          for win, w in pairs(state.windows) do
            if w.buf == bufnr then
              table.insert(wins, win)
            end
          end
          table.sort(wins)
          return wins
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
          -- Snacks' BufWipeout handler clears the key of the wiped instance, whichever instance holds it by then.
          local key = state.buffers[bufnr].key
          if key then
            state.keyed[key] = nil
          end
          for win, w in pairs(state.windows) do
            if w.buf == bufnr then
              state.windows[win] = nil
            end
          end
          state.buffers[bufnr] = nil
          state.running_jobs[jobid] = nil
        end,
        nvim_create_augroup = function(name)
          state.next_augroup = (state.next_augroup or 0) + 1
          return state.next_augroup
        end,
        nvim_create_autocmd = function(event, opts)
          if event == "BufWinEnter" then
            table.insert(state.autocmds, { event = event, group = opts.group, nested = opts.nested })
          end
          if event == "TermClose" and opts.buffer and state.buffers[opts.buffer] then
            state.buffers[opts.buffer].on_term_close = opts.callback
          elseif event == "TermClose" and not opts.buffer then
            table.insert(state.term_close_autocmds, opts.callback)
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
        nvim_win_get_config = function(win)
          local w = state.windows[win]
          return w and w.config or { relative = "" }
        end,
        nvim_win_set_config = function(win, win_config)
          local w = state.windows[win]
          w.config = vim.tbl_deep_extend("force", w.config or { relative = "" }, win_config)
        end,
        nvim_list_wins = function()
          local wins = {}
          for win in pairs(state.windows) do
            table.insert(wins, win)
          end
          table.sort(wins)
          return wins
        end,
        nvim_get_current_win = function()
          return state.current_win
        end,
        nvim_get_current_tabpage = function()
          return state.current_tab
        end,
        nvim_win_get_tabpage = function(win)
          assert(state.windows[win], "Invalid window id: " .. tostring(win))
          return state.windows[win].tab or 1
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
      -- Snacks.win: an instance for an existing buffer (opts.buf), with no window of its own yet. Snacks sets `buf` only
      -- when it shows the instance, and its close wipes the buffer only when it is the instance's scratch buffer.
      win = function(opts)
        local term = {
          opts = {
            wo = opts.wo or {},
            w = opts.w or {},
            position = opts.position,
            width = opts.width,
            height = opts.height,
            bo = { filetype = "snacks_terminal" },
          },
          config = opts,
        }
        function term:buf_valid()
          return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
        end
        function term:close()
          local win, buf = self.win, self.buf
          local wipe = buf ~= nil and buf == self.scratch_buf
          self.win, self.buf = nil, nil
          if win and state.windows[win] then
            state.windows[win] = nil
          end
          if wipe and state.buffers[buf] then
            vim.api.nvim_buf_delete(buf, { force = true })
          end
        end
        term.hide, term.show, term.toggle = function() end, function() end, function() end
        -- Snacks resolves the keys when it creates the instance, and maps them to the buffer (each map closes over the
        -- instance that maps it) when it shows a window or when `map` is called.
        term.keys = opts.keys
        -- Win:show registers these when it opens a window, and an instance that never showed has not.
        state.next_snacks_id = (state.next_snacks_id or 0) + 1
        term.id = state.next_snacks_id
        -- Win.new records these. The close event is bound to a window (`win = true`), the resize is not.
        term.events = { { event = "WinClosed", win = true }, { event = "WinResized" } }
        function term:_on(event, event_opts)
          table.insert(state.events_registered, { term = self, event = event, opts = event_opts })
        end
        function term:fixbuf() end
        function term:map()
          assert(self:buf_valid(), "Snacks.win:map needs a valid buffer")
          state.buffers[self.buf].mapped_by = self
          -- A map only adds or replaces a key. Snacks never removes one.
          local mapped = state.buffers[self.buf].mapped_keys or {}
          for name, spec in pairs(self.keys or {}) do
            mapped[name] = spec
          end
          state.buffers[self.buf].mapped_keys = mapped
        end
        table.insert(state.wrapped, term)
        return term
      end,
      terminal = {
        open = snacks_open,
        -- Snacks.terminal.list: the instances that a key still holds.
        list = function()
          local list = {}
          for _, term in ipairs(state.terminals) do
            if term:buf_valid() and state.keyed[term.key] == term then
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
      assert.are.equal(claude.buf, snacks_provider._get_terminal_for_test().buf)
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

  -- Snacks.terminal.list() keys an instance by its command, directory, env and count, and clears the key when any
  -- buffer with that key is wiped. The provider finds its Claude by the mark and the live job, not by that list.
  it("finds the running Claude when Snacks.terminal.list() does not hold it", function()
    snacks_provider.open("claude", {}, config, true)
    local claude = started[1]
    package.loaded["snacks"].terminal.list = function()
      return {}
    end
    reload_snacks()

    assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
    snacks_provider.open("claude", {}, config, true)
    assert.are.equal(1, #started)
    assert.are.equal(1, running_count())
  end)

  describe("a Claude that the terminal was adopted from", function()
    it("is wrapped in a Snacks window with the options that it started with", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      reload_snacks()

      -- The entry's config differs now, but the window keeps what the terminal started with.
      snacks_provider.open("claude", {}, vim.tbl_deep_extend("force", config, { split_side = "left" }), true)

      assert.are.equal(1, #state.wrapped)
      local wrapped = state.wrapped[1]
      assert.are.equal(claude.buf, wrapped.config.buf)
      assert.is_false(wrapped.config.show)
      assert.are.equal("right", wrapped.config.position)
      assert.are.equal(0.3, wrapped.config.width)
      assert.is_nil(wrapped.config.bo)
      assert.are.equal(claude.buf, wrapped.buf)
    end)

    -- A buffer variable cannot keep a function, nor a table that mixes list and map keys (a key of Snacks does), and the
    -- wrapper takes its keys and its buffer options from the style and the config. So the first start stores none.
    it("stores the window options without the keys, the callbacks and the buffer options", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      assert.is_not_nil(claude.opts.keys, "the instance has keys")
      assert.is_not_nil(claude.opts.bo, "the instance has buffer options")

      local stored = state.buffers[claude.buf].vars.claudecode_snacks_window

      assert.are.equal("right", stored.position)
      assert.is_nil(stored.keys)
      assert.is_nil(stored.bo)
      assert.is_nil(stored.on_buf)
      assert.is_nil(stored.on_win)
    end)

    it("is wiped when the wrapped instance closes", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      reload_snacks()
      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())

      snacks_provider.close()

      assert.is_false(vim.api.nvim_buf_is_valid(claude.buf))
      assert.are.equal(0, running_count())
    end)

    -- Without auto_close the earlier copy registered no TermClose handler, so nothing but the wrapped instance wipes it.
    it("is wiped when the wrapped instance closes, also without auto_close", function()
      snacks_provider.open("claude", {}, { cwd = "/w", split_side = "right", auto_close = false }, true)
      local claude = started[1]
      reload_snacks()
      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())

      snacks_provider.close()

      assert.is_false(vim.api.nvim_buf_is_valid(claude.buf))
      assert.are.equal(0, running_count())
    end)

    -- The TermClose handler belongs to the instance that started the Claude, and it cannot see `closing` on the wrapped
    -- one. Without the mark, it reports the stop of close as a failure.
    it("is not reported as a failure when close stops it", function()
      vim.v.event.status = 129
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      reload_snacks()
      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())

      snacks_provider.close()

      assert.are.equal(0, running_count())
      assert.are.same({}, logged_errors)
    end)

    -- Snacks makes a backdrop window for a float, one z-index below it. The wrapped instance finds it again, so that a
    -- hide and a show reach it too.
    for _, hidden_first in ipairs({ false, true }) do
      it(
        "hides and shows the backdrop of an adopted float (hidden before the reload=" .. tostring(hidden_first) .. ")",
        function()
          snacks_provider.open("claude", {}, config, true)
          local claude = started[1]
          local float = claude.win
          state.windows[float].config = { relative = "editor", zindex = 50, hide = false }
          local backdrop_buf = state.next_bufnr
          state.next_bufnr = state.next_bufnr + 1
          state.buffers[backdrop_buf] = { jobid = 0, vars = {}, filetype = "snacks_win_backdrop" }
          local backdrop = new_window(backdrop_buf)
          state.windows[backdrop].config = { relative = "editor", zindex = 49, hide = false }
          claude.backdrop = { win = backdrop }
          state.buffers[claude.buf].vars.claudecode_snacks_backdrop = backdrop
          if hidden_first then
            snacks_provider.simple_toggle("claude", {}, config)
            assert.is_true(state.windows[backdrop].config.hide)
          end
          reload_snacks()

          snacks_provider.simple_toggle("claude", {}, config)
          local after_first_toggle = hidden_first
          assert.are.equal(after_first_toggle, not state.windows[float].config.hide)
          assert.are.equal(after_first_toggle, not state.windows[backdrop].config.hide)

          snacks_provider.simple_toggle("claude", {}, config)
          assert.are.equal(not after_first_toggle, not state.windows[float].config.hide)
          assert.are.equal(not after_first_toggle, not state.windows[backdrop].config.hide)
        end
      )
    end

    -- Another Snacks float with the default z-index has a backdrop one below it too. Only the one that the first start
    -- named is the terminal's.
    it("does not take the backdrop of another Snacks float", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      state.windows[claude.win].config = { relative = "editor", zindex = 50, hide = false }
      local function backdrop_window()
        local buf = state.next_bufnr
        state.next_bufnr = state.next_bufnr + 1
        state.buffers[buf] = { jobid = 0, vars = {}, filetype = "snacks_win_backdrop" }
        local win = new_window(buf)
        state.windows[win].config = { relative = "editor", zindex = 49, hide = false }
        return win
      end
      local other = backdrop_window() -- another float's, listed first
      local own = backdrop_window()
      state.buffers[claude.buf].vars.claudecode_snacks_backdrop = own
      reload_snacks()

      snacks_provider.simple_toggle("claude", {}, config) -- adopts and hides the float

      assert.is_true(state.windows[own].config.hide)
      assert.is_false(state.windows[other].config.hide)
    end)

    -- The buffer variable names a window, and the window may still exist without being the float's backdrop. The adoption
    -- must not hide a window that is no backdrop one z-index below the float, with a backdrop buffer.
    describe("when the variable names a window that is no backdrop of the float", function()
      local claude, other

      -- A float with a backdrop that the first start named, a reload, and a hide through an entry.
      local function hide_after_reload(float_config, other_config, other_filetype)
        snacks_provider.open("claude", {}, config, true)
        claude = started[1]
        state.windows[claude.win].config = float_config
        local buf = state.next_bufnr
        state.next_bufnr = state.next_bufnr + 1
        state.buffers[buf] = { jobid = 0, vars = {}, filetype = other_filetype }
        other = new_window(buf)
        state.windows[other].config = other_config
        state.buffers[claude.buf].vars.claudecode_snacks_backdrop = other
        reload_snacks()

        snacks_provider.simple_toggle("claude", {}, config) -- adopts and hides the float
        assert.is_true(state.windows[claude.win].config.hide, "the float is hidden")
      end

      it("leaves a window alone that sits at another z-index", function()
        hide_after_reload(
          { relative = "editor", zindex = 50, hide = false },
          { relative = "editor", zindex = 40, hide = false },
          "snacks_win_backdrop"
        )

        assert.is_false(state.windows[other].config.hide)
      end)

      it("leaves a window alone that shows no backdrop buffer", function()
        hide_after_reload(
          { relative = "editor", zindex = 50, hide = false },
          { relative = "editor", zindex = 49, hide = false },
          "markdown"
        )

        assert.is_false(state.windows[other].config.hide)
      end)

      -- A split has no z-index, so it has no backdrop to find.
      it("leaves a window alone when the terminal's window has no z-index", function()
        hide_after_reload(
          { relative = "editor", hide = false },
          { relative = "editor", zindex = 49, hide = false },
          "snacks_win_backdrop"
        )

        assert.is_false(state.windows[other].config.hide)
      end)
    end)

    it("is wrapped in the terminal style, so that q hides it and does not close it", function()
      snacks_provider.open("claude", {}, config, true)
      reload_snacks()

      snacks_provider.open("claude", {}, config, true)

      assert.are.equal("terminal", state.wrapped[1].config.style)
      assert.are.same({}, state.wrapped[1].opts.bo)
    end)

    -- A configless entry (get_active_bufnr) can adopt an older terminal first. The next entry's config must apply before the
    -- check for an ended job.
    it("from an older version is forgotten by the config of the entry after a configless adoption", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      state.buffers[claude.buf].vars.claudecode_snacks_auto_close = nil
      state.buffers[claude.buf].vars.claudecode_snacks_window = nil
      reload_snacks()
      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
      state.running_jobs[state.buffers[claude.buf].jobid] = nil

      snacks_provider.open("claude", {}, config, true)

      assert.are.equal(2, #started)
    end)

    -- An older version wrote neither variable. The entry's config then decides the window options and auto_close.
    for _, auto_close in ipairs({ true, false }) do
      it("from an older version follows the configured auto_close (" .. tostring(auto_close) .. ")", function()
        snacks_provider.open("claude", {}, config, true)
        local claude = started[1]
        state.buffers[claude.buf].vars.claudecode_snacks_auto_close = nil
        state.buffers[claude.buf].vars.claudecode_snacks_window = nil
        reload_snacks()
        local older = vim.tbl_deep_extend("force", config, { auto_close = auto_close, split_side = "left" })
        snacks_provider.open("claude", {}, older, true)
        assert.are.equal("left", state.wrapped[1].config.position)
        assert.are.equal("1: %{get(b:, 'term_title', '')}", state.wrapped[1].config.wo.winbar)

        state.running_jobs[state.buffers[claude.buf].jobid] = nil
        snacks_provider.open("claude", {}, older, true)

        assert.are.equal(auto_close and 2 or 1, #started)
      end)
    end

    -- Snacks maps the keys of an instance to the buffer when it shows a window, and each map closes over that instance.
    -- The maps of the first start close over the instance that started the Claude. Once the wrapper hides and shows the
    -- terminal, that instance has a stale window: q did nothing, and gf left the file in Claude's window.
    it("maps its own keys over those of the instance that started the Claude", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      assert.are.equal(claude, state.buffers[claude.buf].mapped_by)
      reload_snacks()

      snacks_provider.open("claude", {}, config, true)

      assert.are.equal(state.wrapped[1], state.buffers[claude.buf].mapped_by)
    end)

    for _, reloads in ipairs({ 1, 2 }) do
      it("hides with the q key after a hide and a show (reloads=" .. reloads .. ")", function()
        snacks_provider.open("claude", {}, config, true)
        local claude = started[1]
        for _ = 1, reloads do
          reload_snacks()
          snacks_provider.simple_toggle("claude", {}, config) -- adopts, and hides
          snacks_provider.simple_toggle("claude", {}, config) -- shows it in a new window
          assert.are.equal(1, windows_showing(claude.buf))
        end

        state.buffers[claude.buf].mapped_by:hide() -- what q runs

        assert.are.equal(0, windows_showing(claude.buf))
      end)
    end

    -- A key of the user is a function, which a buffer variable cannot keep, so the keys come from the entry's config.
    it("maps the keys of the entry's config, functions included", function()
      local hide_key = { "<C-,>", function() end, mode = "t", desc = "Hide" }
      local configured =
        vim.tbl_deep_extend("force", config, { snacks_win_opts = { keys = { claude_hide = hide_key } } })
      snacks_provider.open("claude", {}, configured, true)
      local claude = started[1]
      reload_snacks()

      snacks_provider.open("claude", {}, configured, true)

      local keys = state.wrapped[1].config.keys
      assert.are.equal(hide_key, keys.claude_hide)
      assert.are.equal("function", type(keys.claude_new_line[2]))
      assert.are.equal(state.wrapped[1], state.buffers[claude.buf].mapped_by)
    end)

    -- An older version stored no window options, and the options that the entry's config builds hold keys that a copy
    -- without functions would break (a key table without its function names an action that does not exist).
    it("maps the real keys of a terminal that an older version started", function()
      local configured = vim.tbl_deep_extend("force", config, { snacks_win_opts = { keys = { claude_hide = "hide" } } })
      snacks_provider.open("claude", {}, configured, true)
      local claude = started[1]
      state.buffers[claude.buf].vars.claudecode_snacks_auto_close = nil
      state.buffers[claude.buf].vars.claudecode_snacks_window = nil
      reload_snacks()

      snacks_provider.open("claude", {}, configured, true)

      local keys = state.wrapped[1].config.keys
      assert.are.equal("function", type(keys.claude_new_line[2]))
      assert.are.equal("hide", keys.claude_hide)
    end)

    -- get_active_bufnr has no config, so the first adoption can come without the user's keys. The next entry brings them.
    it("takes the keys of the next entry's config after a configless adoption", function()
      local hide_key = { "<C-,>", function() end, mode = "t", desc = "Hide" }
      local configured =
        vim.tbl_deep_extend("force", config, { snacks_win_opts = { keys = { claude_hide = hide_key } } })
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      reload_snacks()
      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
      local wrapped = snacks_provider._get_terminal_for_test()
      assert.is_nil(wrapped.keys.claude_hide)

      snacks_provider.simple_toggle("claude", {}, configured)

      assert.are.equal(wrapped, snacks_provider._get_terminal_for_test())
      assert.are.equal(hide_key, wrapped.keys.claude_hide)
      assert.are.equal(wrapped, state.buffers[claude.buf].mapped_by)
      assert.are.equal(hide_key, state.buffers[claude.buf].mapped_keys.claude_hide)
      -- The terminal style sets a filetype. The upgrade must not keep it, or the next update of the window (a resize, a
      -- re-created float) would set it on the Claude buffer.
      assert.are.same({}, wrapped.opts.bo)

      -- The upgrade happens once. A later entry with a config does not build another instance's options.
      assert.are.equal(2, #state.wrapped)
      snacks_provider.simple_toggle("claude", {}, configured)
      snacks_provider.simple_toggle("claude", {}, configured)
      assert.are.equal(2, #state.wrapped)
    end)

    -- An older version stored no window options, so a configless adoption has no size. The next entry's config gives it.
    it("takes the window options of the next entry's config for a terminal of an older version", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      state.buffers[claude.buf].vars.claudecode_snacks_auto_close = nil
      state.buffers[claude.buf].vars.claudecode_snacks_window = nil
      reload_snacks()
      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
      local wrapped = snacks_provider._get_terminal_for_test()

      snacks_provider.simple_toggle(
        "claude",
        {},
        vim.tbl_deep_extend("force", config, { snacks_win_opts = { position = "float", width = 0.9, height = 0.8 } })
      )

      assert.are.equal("float", wrapped.opts.position)
      assert.are.equal(0.9, wrapped.opts.width)
      assert.are.equal(0.8, wrapped.opts.height)
    end)

    it("keeps the stored window options when a later entry has another config", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]
      reload_snacks()
      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
      local wrapped = snacks_provider._get_terminal_for_test()

      snacks_provider.simple_toggle("claude", {}, vim.tbl_deep_extend("force", config, { split_side = "left" }))

      assert.are.equal("right", wrapped.opts.position)
    end)

    it("writes the backdrop of a float that Snacks made at the first start", function()
      local float_config = vim.tbl_deep_extend("force", config, {
        snacks_win_opts = {
          position = "float",
          on_buf = function(instance)
            instance.backdrop = { win = 77 }
          end,
        },
      })

      snacks_provider.open("claude", {}, float_config, true)

      assert.are.equal(77, state.buffers[started[1].buf].vars.claudecode_snacks_backdrop)
    end)

    -- Snacks makes a new backdrop each time it re-creates a float. A reload after that must find the new one.
    it("remembers the backdrop that Snacks makes when it re-creates a float", function()
      local float_config = vim.tbl_deep_extend("force", config, { snacks_win_opts = { position = "float" } })
      snacks_provider.open("claude", {}, float_config, true)
      local claude = started[1]
      state.windows[claude.win].config = { relative = "editor", zindex = 50, hide = false }
      reload_snacks()
      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
      local wrapped = snacks_provider._get_terminal_for_test()
      local backdrop
      -- The float is closed. Snacks re-creates it with a new backdrop.
      state.windows[claude.win] = nil
      wrapped._cc.orig_show = function(self)
        self.win = new_window(self.buf)
        state.windows[self.win].config = { relative = "editor", zindex = 50, hide = false }
        local backdrop_buf = state.next_bufnr
        state.next_bufnr = state.next_bufnr + 1
        state.buffers[backdrop_buf] = { jobid = 0, vars = {}, filetype = "snacks_win_backdrop" }
        backdrop = new_window(backdrop_buf)
        state.windows[backdrop].config = { relative = "editor", zindex = 49, hide = false }
        self.backdrop = { win = backdrop }
      end
      snacks_provider.open("claude", {}, float_config, true)
      assert.are.equal(backdrop, state.buffers[claude.buf].vars.claudecode_snacks_backdrop)

      reload_snacks()
      snacks_provider.simple_toggle("claude", {}, float_config) -- hides the float

      assert.is_true(state.windows[backdrop].config.hide)
    end)

    it("clears the backdrop that it remembers when Snacks re-creates the float without one", function()
      local float_config = vim.tbl_deep_extend("force", config, { snacks_win_opts = { position = "float" } })
      snacks_provider.open("claude", {}, float_config, true)
      local claude = started[1]
      state.buffers[claude.buf].vars.claudecode_snacks_backdrop = 4242
      state.windows[claude.win] = nil
      claude._cc.orig_show = function(self)
        self.win = new_window(self.buf)
      end

      snacks_provider.open("claude", {}, float_config, true)

      assert.is_nil(state.buffers[claude.buf].vars.claudecode_snacks_backdrop)
    end)

    -- A diff in a new tab shows the terminal's buffer in a second window. That copy is no terminal window, as on an
    -- instance that `snacks` started itself, which tracks the window that it showed.
    describe("when a diff tab shows a copy of the terminal", function()
      local claude, copy

      before_each(function()
        snacks_provider.open("claude", {}, config, true)
        claude = started[1]
        reload_snacks()
        assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
        state.current_tab = 2
        copy = new_window(claude.buf)
        state.current_tab = 1
        state.current_win = 1
      end)

      local function showing_in_tab(tab)
        local count = 0
        for _, w in pairs(state.windows) do
          if w.buf == claude.buf and w.tab == tab then
            count = count + 1
          end
        end
        return count
      end

      it("opens Claude in the first tab after a hide there", function()
        snacks_provider.simple_toggle("claude", {}, config) -- hides the window of the first tab
        assert.are.equal(0, showing_in_tab(1))

        snacks_provider.open("claude", {}, config, true)

        assert.are.equal(1, showing_in_tab(1))
        assert.are.equal(1, state.windows[state.current_win].tab)
        assert.are.equal(claude.buf, state.windows[state.current_win].buf)
        assert.is_true(vim.api.nvim_win_is_valid(copy))
      end)

      it("hides its own window from the diff tab, and shows Claude there on the next toggle", function()
        state.current_tab = 2
        state.current_win = copy

        snacks_provider.simple_toggle("claude", {}, config)
        assert.are.equal(0, showing_in_tab(1))
        assert.are.equal(1, showing_in_tab(2))
        assert.is_true(vim.api.nvim_win_is_valid(copy))

        snacks_provider.simple_toggle("claude", {}, config)
        assert.are.equal(2, showing_in_tab(2))
        assert.is_true(vim.api.nvim_win_is_valid(copy))
      end)
    end)

    -- The adoption cannot know which window was the terminal's. A window that Snacks made carries the `snacks_win`
    -- marker, and a copy that a diff tab shows (`nvim_win_set_buf`) does not.
    describe("when the adoption chooses between windows", function()
      local claude, real

      before_each(function()
        snacks_provider.open("claude", {}, config, true)
        claude = started[1]
        real = claude.win
      end)

      local function adopted_window()
        assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
        return snacks_provider._get_terminal_for_test().win
      end

      -- A reload that runs in the diff tab, where a toggle follows: it hides the window that Snacks made, as an
      -- instance that `snacks` started tracks it.
      it("takes the window of Snacks over a copy in the current tab", function()
        state.current_tab = 2
        local copy = new_window(claude.buf)
        reload_snacks()

        assert.are.equal(real, adopted_window())

        snacks_provider.simple_toggle("claude", {}, config)
        assert.is_false(vim.api.nvim_win_is_valid(real))
        assert.is_true(vim.api.nvim_win_is_valid(copy))
      end)

      it("takes the window of Snacks in another tab when the current tab shows none, and an open focuses it", function()
        state.current_tab = 2
        reload_snacks()

        assert.are.equal(real, adopted_window())

        snacks_provider.open("claude", {}, config, true)

        assert.are.equal(real, state.current_win)
        assert.are.equal(1, windows_showing(claude.buf))
        assert.are.equal(1, #started)
      end)

      it("takes the window of Snacks in the current tab first", function()
        state.current_tab = 2
        local other = new_window(claude.buf)
        vim.w[other].snacks_win = { id = 2 }
        reload_snacks()

        assert.are.equal(other, adopted_window())
      end)

      -- Claude is hidden in the first tab, and the diff tab shows a copy. A reload there must not make the open jump.
      it("ignores a copy that only another tab shows, so that an open shows Claude in the current tab", function()
        snacks_provider.simple_toggle("claude", {}, config) -- hides the window of Snacks
        state.current_tab = 2
        local copy = new_window(claude.buf)
        state.current_tab = 1
        state.current_win = 1
        reload_snacks()

        assert.is_nil(adopted_window())

        snacks_provider.open("claude", {}, config, true)

        assert.are_not.equal(copy, state.current_win)
        assert.are.equal(1, state.windows[state.current_win].tab)
        assert.are.equal(claude.buf, state.windows[state.current_win].buf)
      end)

      -- A split that an older version re-created has no marker.
      it("takes a window of the current tab that Snacks did not mark", function()
        state.windows[real] = nil
        local unmarked = new_window(claude.buf)
        reload_snacks()

        assert.are.equal(unmarked, adopted_window())
      end)
    end)

    -- Snacks' Win:show registers the instance's events and a BufWinEnter handler that moves a file that you open in the
    -- terminal's window to another window. A wrapper never ran Win:show, and a split is re-created natively, so the
    -- wrapper registers them at the first re-creation. Without them an :edit in the window replaced Claude's buffer.
    it("registers no window events for a terminal that the provider started, which did at its first show", function()
      snacks_provider.open("claude", {}, config, true)

      snacks_provider.simple_toggle("claude", {}, config)
      snacks_provider.simple_toggle("claude", {}, config)

      assert.are.equal(0, #state.autocmds)
      assert.are.equal(0, #state.events_registered)
    end)

    describe("when the wrapper re-creates a split", function()
      local claude

      before_each(function()
        snacks_provider.open("claude", {}, config, true)
        claude = started[1]
        reload_snacks()
      end)

      it("registers the Snacks events and the BufWinEnter handler of the wrapper", function()
        snacks_provider.simple_toggle("claude", {}, config) -- adopts, and hides
        assert.are.equal(0, #state.autocmds)

        snacks_provider.simple_toggle("claude", {}, config) -- shows it in a new window

        local wrapper = snacks_provider._get_terminal_for_test()
        assert.are.equal(1, #state.autocmds)
        assert.are.equal(wrapper.augroup, state.autocmds[1].group)
        assert.is_true(state.autocmds[1].nested)
        assert.are.equal(1, #state.events_registered)
        assert.are.equal(wrapper, state.events_registered[1].term)
        assert.are.equal("WinResized", state.events_registered[1].event)
        assert.are.equal(1, windows_showing(claude.buf))
      end)

      -- WinClosed is bound to the id of one window, and an instance that `snacks` started never has it for a window that
      -- cc_show re-created. Snacks' handler moves the cursor to the previous window, where main leaves it to Neovim.
      it("registers no event that is bound to a window", function()
        snacks_provider.simple_toggle("claude", {}, config)
        snacks_provider.simple_toggle("claude", {}, config)

        for _, registered in ipairs(state.events_registered) do
          assert.is_not_true(registered.opts.win, registered.event .. " is bound to a window")
        end
        assert.is_true(#state.events_registered > 0)
      end)

      -- `_on` and `fixbuf` are internals of Snacks. A Snacks without one of them must not break the hide and the show.
      for _, missing in ipairs({ "_on", "fixbuf" }) do
        it("skips the registration when Snacks has no " .. missing, function()
          assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
          snacks_provider._get_terminal_for_test()[missing] = nil

          snacks_provider.simple_toggle("claude", {}, config) -- hides
          snacks_provider.simple_toggle("claude", {}, config) -- shows it in a new window

          assert.are.equal(1, windows_showing(claude.buf))
          assert.are.equal(0, #state.autocmds)
          assert.are.equal(0, #state.events_registered)
        end)
      end

      it("registers them once, however often it hides and shows", function()
        for _ = 1, 3 do
          snacks_provider.simple_toggle("claude", {}, config)
          snacks_provider.simple_toggle("claude", {}, config)
        end

        assert.are.equal(1, #state.autocmds)
        assert.are.equal(1, #state.events_registered)
      end)
    end)

    -- A float that is relative to a window has an anchor, and Snacks takes the current window when it has none.
    describe("when the window options hold the anchor of a float", function()
      local function float_config(anchor)
        return vim.tbl_deep_extend(
          "force",
          config,
          { snacks_win_opts = { position = "float", relative = "win", win = anchor } }
        )
      end

      it("keeps the anchor while that window exists", function()
        local anchor = new_window(nil)
        snacks_provider.open("claude", {}, float_config(anchor), true)
        reload_snacks()

        snacks_provider.open("claude", {}, float_config(anchor), true)

        assert.are.equal(anchor, state.wrapped[1].config.win)
      end)

      it("drops the anchor when that window is gone", function()
        local anchor = new_window(nil)
        snacks_provider.open("claude", {}, float_config(anchor), true)
        reload_snacks()
        state.windows[anchor] = nil

        snacks_provider.open("claude", {}, float_config(anchor), true)

        assert.is_nil(state.wrapped[1].config.win)
      end)

      it("stores no anchor for a float that is not relative to a window", function()
        local anchor = new_window(nil)
        local editor = vim.tbl_deep_extend(
          "force",
          config,
          { snacks_win_opts = { position = "float", relative = "editor", win = anchor } }
        )
        snacks_provider.open("claude", {}, editor, true)
        local claude = started[1]
        assert.is_nil(state.buffers[claude.buf].vars.claudecode_snacks_window.win)
      end)
    end)

    -- A map without the config would turn on a key that the user turned off, and Snacks never removes a map. So an
    -- entry without a config (get_active_bufnr, which selection tracking calls on a cursor move) maps nothing.
    it("maps no key when the entry has no config", function()
      local configured = vim.tbl_deep_extend("force", config, { snacks_win_opts = { keys = { term_normal = false } } })
      snacks_provider.open("claude", {}, configured, true)
      local claude = started[1]
      reload_snacks()

      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())

      assert.are.equal(claude, state.buffers[claude.buf].mapped_by)
      assert.is_false(state.buffers[claude.buf].mapped_keys.term_normal)
    end)
  end)

  -- Codex round 3: the plugin reloads, no entry adopts the running Claude, it exits, an entry in the gap starts a new
  -- one, and the next reload must find that one.
  it("finds the Claude that an entry started in the gap, when no entry had adopted the exited one", function()
    snacks_provider.open("claude", {}, config, true)
    local claude = started[1]
    local handler = state.buffers[claude.buf].snacks_term_close
    reload_snacks()
    state.running_jobs[state.buffers[claude.buf].jobid] = nil

    snacks_provider.open("claude", {}, config, true)
    handler()
    while #state.scheduled > 0 do
      table.remove(state.scheduled, 1)()
    end
    assert.are.equal(2, #started)

    reload_snacks()
    assert.are.equal(started[2].buf, snacks_provider.get_active_bufnr())
    snacks_provider.open("claude", {}, config, true)
    assert.are.equal(2, #started)
    assert.are.equal(1, running_count())
  end)

  it("keeps the tracked terminal when another marked terminal appears", function()
    snacks_provider.open("claude", {}, config, true)
    local claude = started[1]
    reload_snacks()
    snacks_provider.open("claude", {}, config, true)
    assert.are.equal(claude.buf, snacks_provider._get_terminal_for_test().buf)
    local other = snacks_open("claude", { win = {}, count = 2 })
    state.buffers[other.buf].vars.claudecode_snacks_terminal = true

    assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
    assert.are.equal(claude.buf, snacks_provider._get_terminal_for_test().buf)
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

  -- The job's exit. `handlers` = false is an exit whose TermClose handlers have not run yet: an autocmd that the user
  -- defined earlier runs before them. Otherwise Snacks' handler of the copy that started the Claude runs, and the
  -- scheduled close that it queues has not run.
  local function exit_job(bufnr, handlers)
    local buf = state.buffers[bufnr]
    state.running_jobs[buf.jobid] = nil
    if handlers ~= false and buf.snacks_term_close then
      buf.snacks_term_close()
    end
  end

  -- Runs the callbacks that vim.schedule queued, like the event loop does.
  local function flush_scheduled()
    while #state.scheduled > 0 do
      table.remove(state.scheduled, 1)()
    end
  end

  describe("a Claude that exited before the scheduled close runs", function()
    for _, entry in ipairs(entries) do
      for _, reload in ipairs({ false, true }) do
        for _, handlers in ipairs({ false, true }) do
          -- Without a reload and with the handler run, the tracked terminal is forgotten at the exit already.
          it(
            string.format(
              "is not shown again by %s (reload=%s, handlers run=%s)",
              entry[1],
              tostring(reload),
              tostring(handlers)
            ),
            function()
              snacks_provider.open("claude", {}, config, true)
              local claude = started[1]
              if reload then
                reload_snacks()
                assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
              end

              exit_job(claude.buf, handlers)
              entry[2]()

              assert.are.equal(2, #started)
              assert.are.equal(1, running_count())
              assert.are.equal(1, windows_showing(started[2].buf))
              assert.are.equal(started[2], snacks_provider._get_terminal_for_test())
            end
          )
        end
      end
    end

    for _, hidden in ipairs({ false, true }) do
      it("is forgotten when it was hidden (hidden=" .. tostring(hidden) .. ")", function()
        snacks_provider.open("claude", {}, config, true)
        local claude = started[1]
        if hidden then
          snacks_provider.simple_toggle("claude", {}, config)
        end
        reload_snacks()
        assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())

        exit_job(claude.buf, false)
        snacks_provider.open("claude", {}, config, true)

        assert.are.equal(2, #started)
        assert.are.equal(started[2], snacks_provider._get_terminal_for_test())
      end)
    end

    -- Snacks keys an instance by its command, directory, env and count, and clears the key when a buffer is wiped. A
    -- Claude that starts before the exited one is wiped has the same key, so the late wipe would drop the new Claude from
    -- Snacks.terminal.list(), and a reload could not find it again.
    for _, provider_first in ipairs({ false, true }) do
      for _, reload in ipairs({ false, true }) do
        it(
          string.format(
            "stays findable after a later reload when an open started it in the gap (provider's handler first=%s, reload before=%s)",
            tostring(provider_first),
            tostring(reload)
          ),
          function()
            snacks_provider.open("claude", {}, config, true)
            local claude = started[1]
            local handler = state.buffers[claude.buf].snacks_term_close
            if reload then
              reload_snacks()
              assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
            end

            exit_job(claude.buf, false)
            if provider_first then
              handler()
            end
            snacks_provider.open("claude", {}, config, true)
            if not provider_first then
              handler()
            end
            flush_scheduled()
            assert.are.equal(2, #started)

            reload_snacks()
            assert.are.equal(started[2].buf, snacks_provider.get_active_bufnr())
            snacks_provider.open("claude", {}, config, true)
            assert.are.equal(2, #started)
            assert.are.equal(1, running_count())
          end
        )
      end
    end

    -- The closed instance has no buffer, and Neovim raises for vim.bo[nil]. Every entry must skip it.
    for _, reload in ipairs({ false, true }) do
      it(
        "raises no error in any entry once the exited instance is closed (reload=" .. tostring(reload) .. ")",
        function()
          snacks_provider.open("claude", {}, config, true)
          local claude = started[1]
          if reload then
            reload_snacks()
            assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
          end
          exit_job(claude.buf, true)
          flush_scheduled()
          assert.is_false(claude:buf_valid())

          for _, entry in ipairs(entries) do
            assert.has_no.errors(entry[2])
          end
          assert.has_no.errors(snacks_provider.get_active_bufnr)
          assert.has_no.errors(snacks_provider.close)
        end
      )
    end

    -- terminal.lua's ensure_visible asks get_active_bufnr and shows nothing when it names a buffer.
    for _, reload in ipairs({ false, true }) do
      it(
        "is not the active buffer, so ensure_visible starts a new Claude (reload=" .. tostring(reload) .. ")",
        function()
          snacks_provider.open("claude", {}, config, true)
          local claude = started[1]
          if reload then
            reload_snacks()
            assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
          end

          exit_job(claude.buf, false)

          assert.is_nil(snacks_provider.get_active_bufnr())
          snacks_provider.open("claude", {}, config, false)
          assert.are.equal(2, #started)
          assert.are.equal(1, running_count())
        end
      )

      it("is not stopped again by close (reload=" .. tostring(reload) .. ")", function()
        snacks_provider.open("claude", {}, config, true)
        local claude = started[1]
        if reload then
          reload_snacks()
          assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())
        end

        exit_job(claude.buf, true)
        snacks_provider.close()
        flush_scheduled()

        assert.is_false(claude:buf_valid())
        assert.are.equal(0, running_count())
        assert.are.same({}, state.exiting_jobs)
        assert.are.same({}, notices)
        assert.is_nil(snacks_provider.get_active_bufnr())
      end)
    end

    -- A wipe inside TermClose would delete the buffer-local autocmds that a user defined after the provider's handler,
    -- in the middle of the event. So the handler schedules the close.
    it("is wiped by the scheduled close, not by the TermClose handler", function()
      snacks_provider.open("claude", {}, config, true)
      local claude = started[1]

      exit_job(claude.buf, true)

      assert.is_true(claude:buf_valid())
      assert.is_nil(snacks_provider._get_terminal_for_test())
      flush_scheduled()
      assert.is_false(claude:buf_valid())
      assert.is_nil(snacks_provider.get_active_bufnr())
    end)

    it("stays tracked without auto_close, which keeps an exited Claude by design", function()
      snacks_provider.open("claude", {}, { cwd = "/w", split_side = "right", auto_close = false }, true)
      local claude = started[1]
      reload_snacks()
      assert.are.equal(claude.buf, snacks_provider.get_active_bufnr())

      exit_job(claude.buf, false)
      snacks_provider.open("claude", {}, config, true)

      assert.are.equal(1, #started)
      assert.are.equal(claude.buf, snacks_provider._get_terminal_for_test().buf)
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

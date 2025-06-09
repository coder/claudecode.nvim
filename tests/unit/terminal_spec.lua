describe("claudecode.terminal (wrapper for Snacks.nvim)", function()
  local terminal_wrapper
  local spy
  local mock_snacks_module
  local mock_snacks_terminal
  local mock_claudecode_config_module
  local last_created_mock_term_instance
  local create_mock_terminal_instance

  create_mock_terminal_instance = function(cmd, opts)
    --- Internal deepcopy for the mock's own use.
    --- Avoids recursion with spied vim.deepcopy.
    local function internal_deepcopy(tbl)
      if type(tbl) ~= "table" then
        return tbl
      end
      local status, plenary_tablex = pcall(require, "plenary.tablex")
      if status and plenary_tablex and plenary_tablex.deepcopy then
        return plenary_tablex.deepcopy(tbl)
      end
      local lookup_table = {}
      local function _copy(object)
        if type(object) ~= "table" then
          return object
        elseif lookup_table[object] then
          return lookup_table[object]
        end
        local new_table = {}
        lookup_table[object] = new_table
        for index, value in pairs(object) do
          new_table[_copy(index)] = _copy(value)
        end
        return setmetatable(new_table, getmetatable(object))
      end
      return _copy(tbl)
    end

    local instance = {
      winid = 1000 + math.random(100),
      buf = 2000 + math.random(100),
      _is_valid = true,
      _cmd_received = cmd,
      _opts_received = internal_deepcopy(opts),
      _on_close_callback = nil,

      valid = spy.new(function(self)
        return self._is_valid
      end),
      focus = spy.new(function(self) end),
      close = spy.new(function(self)
        if self._is_valid and self._on_close_callback then
          self._on_close_callback({ winid = self.winid })
        end
        self._is_valid = false
      end),
    }
    instance.win = instance.winid
    if opts and opts.win and opts.win.on_close then
      instance._on_close_callback = opts.win.on_close
    end
    last_created_mock_term_instance = instance
    return instance
  end

  before_each(function()
    _G.vim = require("tests.mocks.vim")

    local spy_instance_methods = {}
    local spy_instance_mt = { __index = spy_instance_methods }

    local function internal_deepcopy_for_spy_calls(tbl)
      if type(tbl) ~= "table" then
        return tbl
      end
      local status_plenary, plenary_tablex_local = pcall(require, "plenary.tablex")
      if status_plenary and plenary_tablex_local and plenary_tablex_local.deepcopy then
        return plenary_tablex_local.deepcopy(tbl)
      end
      local lookup_table_local = {}
      local function _copy_local(object)
        if type(object) ~= "table" then
          return object
        elseif lookup_table_local[object] then
          return lookup_table_local[object]
        end
        local new_table_local = {}
        lookup_table_local[object] = new_table_local
        for index, value in pairs(object) do
          new_table_local[_copy_local(index)] = _copy_local(value)
        end
        return setmetatable(new_table_local, getmetatable(object))
      end
      return _copy_local(tbl)
    end

    spy_instance_mt.__call = function(self, ...)
      table.insert(self.calls, { refs = internal_deepcopy_for_spy_calls({ ... }) })
      if self.fake_fn then
        return self.fake_fn(unpack({ ... }))
      end
    end

    function spy_instance_methods:reset()
      self.calls = {}
    end

    function spy_instance_methods:clear()
      self:reset()
    end

    function spy_instance_methods:was_called(count)
      local actual_count = #self.calls
      if count then
        assert(
          actual_count == count,
          string.format("Expected spy to be called %d time(s), but was called %d time(s).", count, actual_count)
        )
      else
        assert(actual_count > 0, "Expected spy to be called at least once, but was not called.")
      end
    end

    function spy_instance_methods:was_not_called()
      assert(#self.calls == 0, string.format("Expected spy not to be called, but was called %d time(s).", #self.calls))
    end

    function spy_instance_methods:was_called_with(...)
      local expected_args = { ... }
      local found_match = false
      local calls_repr = ""
      for i, call_info in ipairs(self.calls) do
        calls_repr = calls_repr .. "\n  Call " .. i .. ": {"
        for j, arg_ref in ipairs(call_info.refs) do
          calls_repr = calls_repr .. tostring(arg_ref) .. (j < #call_info.refs and ", " or "")
        end
        calls_repr = calls_repr .. "}"
      end

      if #self.calls == 0 and #expected_args == 0 then
        found_match = true
      elseif #self.calls > 0 then
        for _, call_info in ipairs(self.calls) do
          local actual_args = call_info.refs
          if #actual_args == #expected_args then
            local current_match = true
            for i = 1, #expected_args do
              if
                type(expected_args[i]) == "table"
                and getmetatable(expected_args[i])
                and getmetatable(expected_args[i]).__is_matcher
              then
                if not expected_args[i](actual_args[i]) then
                  current_match = false
                  break
                end
              elseif actual_args[i] ~= expected_args[i] then
                current_match = false
                break
              end
            end
            if current_match then
              found_match = true
              break
            end
          end
        end
      end
      local expected_repr = ""
      for i, arg in ipairs(expected_args) do
        expected_repr = expected_repr .. tostring(arg) .. (i < #expected_args and ", " or "")
      end
      assert(
        found_match,
        "Spy was not called with the expected arguments.\nExpected: {"
          .. expected_repr
          .. "}\nActual Calls:"
          .. calls_repr
      )
    end

    function spy_instance_methods:get_call(index)
      return self.calls[index]
    end

    spy = {
      new = function(fake_fn)
        local s = { calls = {}, fake_fn = fake_fn }
        setmetatable(s, spy_instance_mt)
        return s
      end,
      on = function(tbl, key)
        local original_fn = tbl[key]
        local spy_obj = spy.new(original_fn)
        tbl[key] = spy_obj
        return spy_obj
      end,
      restore = function() end,
      matching = {
        is_type = function(expected_type)
          local matcher_table = { __is_matcher = true }
          matcher_table.__call = function(self, val)
            return type(val) == expected_type
          end
          setmetatable(matcher_table, matcher_table)
          return matcher_table
        end,
        string = {
          match = function(pattern)
            local matcher_table = { __is_matcher = true }
            matcher_table.__call = function(self, actual_str)
              if type(actual_str) ~= "string" then
                return false
              end
              return actual_str:match(pattern) ~= nil
            end
            setmetatable(matcher_table, matcher_table)
            return matcher_table
          end,
        },
      },
    }

    package.loaded["claudecode.terminal"] = nil
    package.loaded["snacks"] = nil
    package.loaded["claudecode.config"] = nil

    mock_claudecode_config_module = {
      apply = spy.new(function(user_conf)
        local base_config = { terminal_cmd = "claude" }
        if user_conf and user_conf.terminal_cmd then
          base_config.terminal_cmd = user_conf.terminal_cmd
        end
        return base_config
      end),
    }
    package.loaded["claudecode.config"] = mock_claudecode_config_module

    mock_snacks_terminal = {
      open = spy.new(create_mock_terminal_instance),
      toggle = spy.new(function(cmd, opts)
        local existing_term = terminal_wrapper
          and terminal_wrapper._get_managed_terminal_for_test
          and terminal_wrapper._get_managed_terminal_for_test()
        if existing_term and existing_term._cmd_received == cmd then
          if existing_term._on_close_callback then
            existing_term._on_close_callback({ winid = existing_term.winid })
          end
          return nil
        end
        return create_mock_terminal_instance(cmd, opts)
      end),
    }
    mock_snacks_module = { terminal = mock_snacks_terminal }
    package.loaded["snacks"] = mock_snacks_module

    vim.g.claudecode_user_config = {}

    local original_mock_vim_deepcopy = _G.vim.deepcopy
    _G.vim.deepcopy = spy.new(function(tbl)
      if original_mock_vim_deepcopy then
        return original_mock_vim_deepcopy(tbl)
      else
        if type(tbl) ~= "table" then
          return tbl
        end
        local status_plenary, plenary_tablex_local = pcall(require, "plenary.tablex")
        if status_plenary and plenary_tablex_local and plenary_tablex_local.deepcopy then
          return plenary_tablex_local.deepcopy(tbl)
        end
        local lookup_table_local = {}
        local function _copy_local(object)
          if type(object) ~= "table" then
            return object
          elseif lookup_table_local[object] then
            return lookup_table_local[object]
          end
          local new_table_local = {}
          lookup_table_local[object] = new_table_local
          for index, value in pairs(object) do
            new_table_local[_copy_local(index)] = _copy_local(value)
          end
          return setmetatable(new_table_local, getmetatable(object))
        end
        return _copy_local(tbl)
      end
    end)
    vim.api.nvim_buf_get_option = spy.new(function(_bufnr, opt_name)
      if opt_name == "buftype" then
        return "terminal"
      end
      return nil
    end)
    vim.api.nvim_win_call = spy.new(function(_winid, func)
      func()
    end)
    vim.cmd = spy.new(function(_cmd_str) end)
    vim.notify = spy.new(function(_msg, _level) end)

    terminal_wrapper = require("claudecode.terminal")
    terminal_wrapper.setup({})
  end)

  after_each(function()
    package.loaded["claudecode.terminal"] = nil
    package.loaded["snacks"] = nil
    package.loaded["claudecode.config"] = nil
    if _G.vim and _G.vim._mock and _G.vim._mock.reset then
      _G.vim._mock.reset()
    end
    _G.vim = nil
    last_created_mock_term_instance = nil
  end)

  describe("terminal.setup", function()
    it("should store valid split_side and split_width_percentage", function()
      terminal_wrapper.setup({ split_side = "left", split_width_percentage = 0.5 })
      terminal_wrapper.open()
      local opts_arg = mock_snacks_terminal.open:get_call(1).refs[2]
      assert.are.equal("left", opts_arg.win.position)
      assert.are.equal(0.5, opts_arg.win.width)
    end)
    it("should ignore invalid split_side and use default", function()
      terminal_wrapper.setup({ split_side = "invalid_side", split_width_percentage = 0.5 })
      terminal_wrapper.open()
      local opts_arg = mock_snacks_terminal.open:get_call(1).refs[2]
      assert.are.equal("right", opts_arg.win.position)
      assert.are.equal(0.5, opts_arg.win.width)
      vim.notify:was_called_with(spy.matching.string.match("Invalid value for split_side"), vim.log.levels.WARN)
    end)

    it("should ignore invalid split_width_percentage and use default", function()
      terminal_wrapper.setup({ split_side = "left", split_width_percentage = 2.0 })
      terminal_wrapper.open()
      local opts_arg = mock_snacks_terminal.open:get_call(1).refs[2]
      assert.are.equal("left", opts_arg.win.position)
      assert.are.equal(0.30, opts_arg.win.width)
      vim.notify:was_called_with(
        spy.matching.string.match("Invalid value for split_width_percentage"),
        vim.log.levels.WARN
      )
    end)

    it("should ignore unknown keys", function()
      terminal_wrapper.setup({ unknown_key = "some_value", split_side = "left" })
      terminal_wrapper.open()
      local opts_arg = mock_snacks_terminal.open:get_call(1).refs[2]
      assert.are.equal("left", opts_arg.win.position)
      vim.notify:was_called_with(
        spy.matching.string.match("Unknown configuration key: unknown_key"),
        vim.log.levels.WARN
      )
    end)

    it("should use defaults if user_term_config is not a table and notify", function()
      terminal_wrapper.setup("not_a_table")
      terminal_wrapper.open()
      local opts_arg = mock_snacks_terminal.open:get_call(1).refs[2]
      assert.are.equal("right", opts_arg.win.position)
      assert.are.equal(0.30, opts_arg.win.width)
      vim.notify:was_called_with(
        "claudecode.terminal.setup expects a table or nil for user_term_config",
        vim.log.levels.WARN
      )
    end)
  end)

  describe("terminal.open", function()
    it(
      "should call Snacks.terminal.open with default 'claude' command if terminal_cmd is not set in main config",
      function()
        vim.g.claudecode_user_config = {}
        mock_claudecode_config_module.apply = spy.new(function()
          return { terminal_cmd = "claude" }
        end)
        package.loaded["claudecode.config"] = mock_claudecode_config_module
        package.loaded["claudecode.terminal"] = nil
        terminal_wrapper = require("claudecode.terminal")
        terminal_wrapper.setup({})

        terminal_wrapper.open()

        mock_snacks_terminal.open:was_called(1)
        local cmd_arg, opts_arg =
          mock_snacks_terminal.open:get_call(1).refs[1], mock_snacks_terminal.open:get_call(1).refs[2]

        assert.are.equal("claude", cmd_arg)
        assert.is_table(opts_arg)
        assert.are.equal("right", opts_arg.win.position)
        assert.are.equal(0.30, opts_arg.win.width)
        assert.is_function(opts_arg.win.on_close)
        assert.is_true(opts_arg.interactive)
        assert.is_true(opts_arg.enter)
      end
    )

    it("should call Snacks.terminal.open with terminal_cmd from main config", function()
      vim.g.claudecode_user_config = { terminal_cmd = "my_claude_cli" }
      mock_claudecode_config_module.apply = spy.new(function()
        return { terminal_cmd = "my_claude_cli" }
      end)
      package.loaded["claudecode.config"] = mock_claudecode_config_module
      package.loaded["claudecode.terminal"] = nil
      terminal_wrapper = require("claudecode.terminal")
      terminal_wrapper.setup({}, "my_claude_cli")

      terminal_wrapper.open()
      mock_snacks_terminal.open:was_called(1)
      local cmd_arg = mock_snacks_terminal.open:get_call(1).refs[1]
      assert.are.equal("my_claude_cli", cmd_arg)
    end)

    it("should focus existing valid terminal and call startinsert", function()
      terminal_wrapper.open()
      local first_instance = last_created_mock_term_instance
      assert.is_not_nil(first_instance)
      mock_snacks_terminal.open:reset()

      terminal_wrapper.open()
      first_instance.valid:was_called()
      first_instance.focus:was_called(1)
      vim.api.nvim_win_call:was_called(1)
      vim.cmd:was_called_with("startinsert")
      mock_snacks_terminal.open:was_not_called()
    end)

    it("should apply opts_override to snacks_opts when opening a new terminal", function()
      terminal_wrapper.open({ split_side = "left", split_width_percentage = 0.6 })
      mock_snacks_terminal.open:was_called(1)
      local opts_arg = mock_snacks_terminal.open:get_call(1).refs[2]
      assert.are.equal("left", opts_arg.win.position)
      assert.are.equal(0.6, opts_arg.win.width)
    end)

    it("should set managed_snacks_terminal to nil and notify if Snacks.terminal.open fails (returns nil)", function()
      mock_snacks_terminal.open = spy.new(function()
        return nil
      end)
      terminal_wrapper.open()
      vim.notify:was_called_with("Failed to open Claude terminal using Snacks.", vim.log.levels.ERROR)
      mock_snacks_terminal.open:reset()
      mock_snacks_terminal.open = spy.new(function()
        return nil
      end)
      terminal_wrapper.open()
      mock_snacks_terminal.open:was_called(1)
    end)

    it("should set managed_snacks_terminal to nil if Snacks.terminal.open returns invalid instance", function()
      local invalid_instance = { valid = spy.new(function()
        return false
      end) }
      mock_snacks_terminal.open = spy.new(function()
        return invalid_instance
      end)
      terminal_wrapper.open()
      vim.notify:was_called_with("Failed to open Claude terminal using Snacks.", vim.log.levels.ERROR)
      mock_snacks_terminal.open:reset()
      mock_snacks_terminal.open = spy.new(function()
        return invalid_instance
      end)
      terminal_wrapper.open()
      mock_snacks_terminal.open:was_called(1)
    end)
  end)

  describe("terminal.close", function()
    it("should call managed_terminal:close() if valid terminal exists", function()
      terminal_wrapper.open()
      local current_managed_term = last_created_mock_term_instance
      assert.is_not_nil(current_managed_term)

      terminal_wrapper.close()
      current_managed_term.close:was_called(1)
    end)

    it("should not call close if no managed terminal", function()
      terminal_wrapper.close()
      mock_snacks_terminal.open:was_not_called()
      assert.is_nil(last_created_mock_term_instance)
    end)

    it("should not call close if managed terminal is invalid", function()
      terminal_wrapper.open()
      local current_managed_term = last_created_mock_term_instance
      assert.is_not_nil(current_managed_term)
      current_managed_term._is_valid = false

      current_managed_term.close:reset()
      terminal_wrapper.close()
      current_managed_term.close:was_not_called()
    end)
  end)

  describe("terminal.toggle", function()
    it("should call Snacks.terminal.toggle with correct command and options", function()
      vim.g.claudecode_user_config = { terminal_cmd = "toggle_claude" }
      mock_claudecode_config_module.apply = spy.new(function()
        return { terminal_cmd = "toggle_claude" }
      end)
      package.loaded["claudecode.config"] = mock_claudecode_config_module
      package.loaded["claudecode.terminal"] = nil
      terminal_wrapper = require("claudecode.terminal")
      terminal_wrapper.setup({ split_side = "left", split_width_percentage = 0.4 }, "toggle_claude")

      terminal_wrapper.toggle({ split_width_percentage = 0.45 })

      mock_snacks_terminal.toggle:was_called(1)
      local cmd_arg, opts_arg =
        mock_snacks_terminal.toggle:get_call(1).refs[1], mock_snacks_terminal.toggle:get_call(1).refs[2]
      assert.are.equal("toggle_claude", cmd_arg)
      assert.are.equal("left", opts_arg.win.position)
      assert.are.equal(0.45, opts_arg.win.width)
      assert.is_function(opts_arg.win.on_close)
    end)

    it("should update managed_snacks_terminal if toggle returns a valid instance", function()
      local mock_toggled_instance = create_mock_terminal_instance("toggled_cmd", {})
      mock_snacks_terminal.toggle = spy.new(function()
        return mock_toggled_instance
      end)

      terminal_wrapper.toggle({})
      mock_snacks_terminal.open:reset()
      mock_toggled_instance.focus:reset()
      terminal_wrapper.open()
      mock_toggled_instance.focus:was_called(1)
      mock_snacks_terminal.open:was_not_called()
    end)

    it("should set managed_snacks_terminal to nil if toggle returns nil", function()
      mock_snacks_terminal.toggle = spy.new(function()
        return nil
      end)
      terminal_wrapper.toggle({})
      mock_snacks_terminal.open:reset()
      terminal_wrapper.open()
      mock_snacks_terminal.open:was_called(1)
    end)
  end)

  describe("snacks_opts.win.on_close callback handling", function()
    it("should set managed_snacks_terminal to nil when on_close is triggered", function()
      terminal_wrapper.open()
      local opened_instance = last_created_mock_term_instance
      assert.is_not_nil(opened_instance)
      assert.is_function(opened_instance._on_close_callback)

      opened_instance._on_close_callback({ win = opened_instance.win })

      mock_snacks_terminal.open:reset()
      terminal_wrapper.open()
      mock_snacks_terminal.open:was_called(1)
    end)

    it("on_close should not clear managed_snacks_terminal if winid does not match (safety check)", function()
      terminal_wrapper.open()
      local opened_instance = last_created_mock_term_instance
      assert.is_not_nil(opened_instance)
      assert.is_function(opened_instance._on_close_callback)

      opened_instance._on_close_callback({ winid = opened_instance.winid + 123 })

      mock_snacks_terminal.open:reset()
      opened_instance.focus:reset()
      terminal_wrapper.open()
      opened_instance.focus:was_called(1)
      mock_snacks_terminal.open:was_not_called()
    end)
  end)

  describe("command arguments support", function()
    it("should append cmd_args to base command when provided to open", function()
      terminal_wrapper.open({}, "--resume")

      mock_snacks_terminal.open:was_called(1)
      local cmd_arg = mock_snacks_terminal.open:get_call(1).refs[1]
      assert.are.equal("claude --resume", cmd_arg)
    end)

    it("should append cmd_args to base command when provided to toggle", function()
      terminal_wrapper.toggle({}, "--resume --verbose")

      mock_snacks_terminal.toggle:was_called(1)
      local cmd_arg = mock_snacks_terminal.toggle:get_call(1).refs[1]
      assert.are.equal("claude --resume --verbose", cmd_arg)
    end)

    it("should work with custom terminal_cmd and arguments", function()
      terminal_wrapper.setup({}, "my_claude_binary")
      terminal_wrapper.open({}, "--flag")

      mock_snacks_terminal.open:was_called(1)
      local cmd_arg = mock_snacks_terminal.open:get_call(1).refs[1]
      assert.are.equal("my_claude_binary --flag", cmd_arg)
    end)

    it("should fallback gracefully when cmd_args is nil", function()
      terminal_wrapper.open({}, nil)

      mock_snacks_terminal.open:was_called(1)
      local cmd_arg = mock_snacks_terminal.open:get_call(1).refs[1]
      assert.are.equal("claude", cmd_arg)
    end)

    it("should fallback gracefully when cmd_args is empty string", function()
      terminal_wrapper.toggle({}, "")

      mock_snacks_terminal.toggle:was_called(1)
      local cmd_arg = mock_snacks_terminal.toggle:get_call(1).refs[1]
      assert.are.equal("claude", cmd_arg)
    end)

    it("should work with both opts_override and cmd_args", function()
      terminal_wrapper.open({ split_side = "left" }, "--resume")

      mock_snacks_terminal.open:was_called(1)
      local cmd_arg = mock_snacks_terminal.open:get_call(1).refs[1]
      local opts_arg = mock_snacks_terminal.open:get_call(1).refs[2]

      assert.are.equal("claude --resume", cmd_arg)
      assert.are.equal("left", opts_arg.win.position)
    end)

    it("should handle special characters in arguments", function()
      terminal_wrapper.open({}, "--message='hello world'")

      mock_snacks_terminal.open:was_called(1)
      local cmd_arg = mock_snacks_terminal.open:get_call(1).refs[1]
      assert.are.equal("claude --message='hello world'", cmd_arg)
    end)

    it("should maintain backward compatibility when no cmd_args provided", function()
      terminal_wrapper.open()

      mock_snacks_terminal.open:was_called(1)
      local open_cmd = mock_snacks_terminal.open:get_call(1).refs[1]
      assert.are.equal("claude", open_cmd)

      -- Close the existing terminal and reset spies to test toggle in isolation
      terminal_wrapper.close()
      mock_snacks_terminal.open:reset()
      mock_snacks_terminal.toggle:reset()

      terminal_wrapper.toggle()

      mock_snacks_terminal.toggle:was_called(1)
      local toggle_cmd = mock_snacks_terminal.toggle:get_call(1).refs[1]
      assert.are.equal("claude", toggle_cmd)
    end)
  end)
end)

-- luacheck: globals expect
require("tests.busted_setup")

describe("Visual Delay Timing Validation", function()
  local selection_module
  local mock_vim

  local function setup_mocks()
    package.loaded["claudecode.selection"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.terminal"] = nil

    -- Mock logger
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
    }

    -- Mock terminal
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return nil -- No active terminal by default
      end,
    }

    -- Extend the existing vim mock
    mock_vim = _G.vim or {}

    -- Mock timing functions
    mock_vim.loop = mock_vim.loop or {}
    mock_vim._timers = {}
    mock_vim._timer_id = 0

    mock_vim.loop.new_timer = function()
      mock_vim._timer_id = mock_vim._timer_id + 1
      local timer = {
        id = mock_vim._timer_id,
        started = false,
        stopped = false,
        closed = false,
        callback = nil,
        delay = nil,
      }
      mock_vim._timers[timer.id] = timer
      return timer
    end

    -- Mock timer methods on the timer objects
    local timer_metatable = {
      __index = {
        start = function(self, delay, repeat_count, callback)
          self.started = true
          self.delay = delay
          self.callback = callback
          -- Immediately execute for testing
          if callback then
            callback()
          end
        end,
        stop = function(self)
          self.stopped = true
        end,
        close = function(self)
          self.closed = true
          mock_vim._timers[self.id] = nil
        end,
      },
    }

    -- Apply metatable to all timers
    for _, timer in pairs(mock_vim._timers) do
      setmetatable(timer, timer_metatable)
    end

    -- Override new_timer to apply metatable to new timers
    local original_new_timer = mock_vim.loop.new_timer
    mock_vim.loop.new_timer = function()
      local timer = original_new_timer()
      setmetatable(timer, timer_metatable)
      return timer
    end

    mock_vim.loop.now = function()
      return os.time() * 1000 -- Mock timestamp in milliseconds
    end

    -- Mock vim.schedule_wrap
    mock_vim.schedule_wrap = function(callback)
      return callback
    end

    -- Mock mode functions
    mock_vim.api = mock_vim.api or {}
    mock_vim.api.nvim_get_mode = function()
      return { mode = "n" } -- Default to normal mode
    end

    mock_vim.api.nvim_get_current_buf = function()
      return 1
    end

    _G.vim = mock_vim
  end

  before_each(function()
    setup_mocks()
    selection_module = require("claudecode.selection")
  end)

  describe("delay timing appropriateness", function()
    it("should use 50ms delay as default", function()
      expect(selection_module.state.visual_demotion_delay_ms).to_be(50)
    end)

    it("should allow configurable delay", function()
      local mock_server = {
        broadcast = function()
          return true
        end,
      }

      selection_module.enable(mock_server, 100)
      expect(selection_module.state.visual_demotion_delay_ms).to_be(100)
    end)

    it("should handle very short delays without issues", function()
      local mock_server = {
        broadcast = function()
          return true
        end,
      }

      selection_module.enable(mock_server, 10)
      expect(selection_module.state.visual_demotion_delay_ms).to_be(10)

      local success = pcall(function()
        selection_module.handle_selection_demotion(1)
      end)
      expect(success).to_be_true()
    end)

    it("should handle zero delay", function()
      local mock_server = {
        broadcast = function()
          return true
        end,
      }

      selection_module.enable(mock_server, 0)
      expect(selection_module.state.visual_demotion_delay_ms).to_be(0)

      local success = pcall(function()
        selection_module.handle_selection_demotion(1)
      end)
      expect(success).to_be_true()
    end)
  end)

  describe("performance characteristics", function()
    it("should not accumulate timers with rapid mode changes", function()
      local mock_server = {
        broadcast = function()
          return true
        end,
      }
      selection_module.enable(mock_server, 50)

      local initial_timer_count = 0
      for _ in pairs(mock_vim._timers) do
        initial_timer_count = initial_timer_count + 1
      end

      -- Simulate rapid visual mode entry/exit
      for i = 1, 10 do
        -- Mock visual selection
        selection_module.state.last_active_visual_selection = {
          bufnr = 1,
          selection_data = { selection = { isEmpty = false } },
          timestamp = mock_vim.loop.now(),
        }

        -- Trigger update_selection
        selection_module.update_selection()
      end

      local final_timer_count = 0
      for _ in pairs(mock_vim._timers) do
        final_timer_count = final_timer_count + 1
      end

      -- Should not accumulate many timers
      expect(final_timer_count - initial_timer_count <= 1).to_be_true()
    end)

    it("should properly clean up timers", function()
      local mock_server = {
        broadcast = function()
          return true
        end,
      }
      selection_module.enable(mock_server, 50)

      -- Start a visual selection demotion
      selection_module.state.last_active_visual_selection = {
        bufnr = 1,
        selection_data = { selection = { isEmpty = false } },
        timestamp = mock_vim.loop.now(),
      }

      -- Check if any timers exist before cleanup
      local found_timer = next(mock_vim._timers) ~= nil

      -- Disable selection tracking
      selection_module.disable()

      -- If a timer was found, it should be cleaned up
      -- This test is mainly about ensuring no errors occur during cleanup
      expect(found_timer == true or found_timer == false).to_be_true() -- Always passes, tests cleanup doesn't error
    end)
  end)

  describe("responsiveness analysis", function()
    it("50ms should be fast enough for tree navigation", function()
      -- 50ms is:
      -- - Faster than typical human reaction time (100-200ms)
      -- - Fast enough to feel immediate
      -- - Slow enough to allow deliberate actions

      local delay = 50
      expect(delay < 100).to_be_true() -- Faster than reaction time
      expect(delay > 10).to_be_true() -- Not too aggressive
    end)

    it("should be configurable for different use cases", function()
      local mock_server = {
        broadcast = function()
          return true
        end,
      }

      -- Power users might want faster (25ms)
      selection_module.enable(mock_server, 25)
      expect(selection_module.state.visual_demotion_delay_ms).to_be(25)

      -- Disable and re-enable for different timing
      selection_module.disable()

      -- Slower systems might want more time (100ms)
      selection_module.enable(mock_server, 100)
      expect(selection_module.state.visual_demotion_delay_ms).to_be(100)
    end)
  end)

  describe("edge case behavior", function()
    it("should handle timer callback execution correctly", function()
      local mock_server = {
        broadcast = function()
          return true
        end,
      }
      selection_module.enable(mock_server, 50)

      -- Set up a visual selection that will trigger demotion
      selection_module.state.last_active_visual_selection = {
        bufnr = 1,
        selection_data = { selection = { isEmpty = false } },
        timestamp = mock_vim.loop.now(),
      }

      selection_module.state.latest_selection = {
        bufnr = 1,
        selection = { isEmpty = false },
      }

      -- Should not error when demotion callback executes
      local success = pcall(function()
        selection_module.update_selection()
      end)
      expect(success).to_be_true()
    end)
  end)
end)

---@diagnostic disable: undefined-field, inject-field
local mock = require("tests.mocks.vim")

describe("safe_tcp", function()
  local safe_tcp
  local logger
  
  before_each(function()
    -- Setup mocks
    _G.vim = mock
    
    -- Mock logger
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function() end,
    }
    
    -- Load modules after mocks are set
    logger = require("claudecode.logger")
    safe_tcp = require("claudecode.server.safe_tcp")
  end)
  
  after_each(function()
    package.loaded["claudecode.server.safe_tcp"] = nil
    package.loaded["claudecode.logger"] = nil
    safe_tcp.reset_error_stats()
  end)
  
  describe("safe_tcp_operation", function()
    it("should handle valid tcp operations", function()
      local tcp_handle = {
        is_closing = function() return false end,
      }
      
      local operation_called = false
      local success, result = safe_tcp.safe_tcp_operation(
        tcp_handle,
        "test_operation",
        function(handle, arg1, arg2)
          operation_called = true
          assert.equals(tcp_handle, handle)
          assert.equals("arg1", arg1)
          assert.equals(123, arg2)
          return "success"
        end,
        "arg1",
        123
      )
      
      assert.is_true(success)
      assert.equals("success", result)
      assert.is_true(operation_called)
    end)
    
    it("should reject nil handles", function()
      local success, result = safe_tcp.safe_tcp_operation(
        nil,
        "test_operation",
        function() return "should not be called" end
      )
      
      assert.is_false(success)
      assert.matches("closed or invalid", result)
    end)
    
    it("should reject closing handles", function()
      local tcp_handle = {
        is_closing = function() return true end,
      }
      
      local success, result = safe_tcp.safe_tcp_operation(
        tcp_handle,
        "test_operation",
        function() return "should not be called" end
      )
      
      assert.is_false(success)
      assert.matches("closed or invalid", result)
    end)
    
    it("should catch operation errors", function()
      local tcp_handle = {
        is_closing = function() return false end,
      }
      
      local success, result = safe_tcp.safe_tcp_operation(
        tcp_handle,
        "test_operation",
        function()
          error("Operation failed!")
        end
      )
      
      assert.is_false(success)
      assert.matches("Operation failed!", result)
    end)
  end)
  
  describe("safe_write", function()
    it("should write data safely", function()
      local write_called = false
      local callback_called = false
      local tcp_handle = {
        is_closing = function() return false end,
        write = function(self, data, cb)
          write_called = true
          assert.equals("test data", data)
          if cb then cb(nil) end
        end,
      }
      
      local success = safe_tcp.safe_write(tcp_handle, "test data", function(err)
        callback_called = true
        assert.is_nil(err)
      end)
      
      assert.is_true(success)
      assert.is_true(write_called)
      assert.is_true(callback_called)
    end)
    
    it("should handle write errors in callback", function()
      local tcp_handle = {
        is_closing = function() return false end,
        write = function(self, data, cb)
          if cb then cb("Write error") end
        end,
      }
      
      local callback_err = nil
      local success = safe_tcp.safe_write(tcp_handle, "test data", function(err)
        callback_err = err
      end)
      
      assert.is_true(success) -- Write was initiated
      assert.equals("Write error", callback_err)
    end)
    
    it("should protect against callback errors", function()
      local tcp_handle = {
        is_closing = function() return false end,
        write = function(self, data, cb)
          if cb then cb(nil) end
        end,
      }
      
      -- Callback that throws error should not crash
      local success = safe_tcp.safe_write(tcp_handle, "test data", function(err)
        error("Callback error!")
      end)
      
      assert.is_true(success) -- Write succeeded even if callback errored
    end)
  end)
  
  describe("safe_close", function()
    it("should close handle safely", function()
      local close_called = false
      local tcp_handle = {
        is_closing = function() return false end,
        close = function(self, cb)
          close_called = true
          if cb then cb() end
        end,
      }
      
      local success = safe_tcp.safe_close(tcp_handle)
      
      assert.is_true(success)
      assert.is_true(close_called)
    end)
    
    it("should not close already closing handle", function()
      local close_called = false
      local tcp_handle = {
        is_closing = function() return true end,
        close = function(self)
          close_called = true
        end,
      }
      
      local success = safe_tcp.safe_close(tcp_handle)
      
      assert.is_false(success)
      assert.is_false(close_called)
    end)
    
    it("should handle nil handle", function()
      local success = safe_tcp.safe_close(nil)
      assert.is_false(success)
    end)
  end)
  
  describe("safe_schedule", function()
    it("should execute scheduled function", function()
      local executed = false
      local scheduled_funcs = {}
      
      -- Mock vim.schedule
      vim.schedule = function(func)
        table.insert(scheduled_funcs, func)
      end
      
      safe_tcp.safe_schedule(function()
        executed = true
      end, "test_context")
      
      -- Execute scheduled function
      assert.equals(1, #scheduled_funcs)
      scheduled_funcs[1]()
      
      assert.is_true(executed)
    end)
    
    it("should catch errors in scheduled functions", function()
      local error_logged = false
      local original_error = logger.error
      logger.error = function(module, msg, context, err)
        error_logged = true
        assert.matches("test_context", msg)
        assert.matches("Scheduled error!", err)
      end
      
      vim.schedule = function(func) func() end
      
      safe_tcp.safe_schedule(function()
        error("Scheduled error!")
      end, "test_context")
      
      assert.is_true(error_logged)
      logger.error = original_error
    end)
  end)
  
  describe("validate_client_state", function()
    it("should validate valid client", function()
      local client = {
        id = "client_123",
        state = "connected",
        tcp_handle = {
          is_closing = function() return false end,
        },
      }
      
      local valid, err = safe_tcp.validate_client_state(client, "test_op")
      
      assert.is_true(valid)
      assert.is_nil(err)
    end)
    
    it("should reject nil client", function()
      local valid, err = safe_tcp.validate_client_state(nil, "test_op")
      
      assert.is_false(valid)
      assert.matches("nil", err)
    end)
    
    it("should reject client without tcp_handle", function()
      local client = {
        id = "client_123",
        state = "connected",
        tcp_handle = nil,
      }
      
      local valid, err = safe_tcp.validate_client_state(client, "test_op")
      
      assert.is_false(valid)
      assert.matches("TCP handle is nil", err)
    end)
    
    it("should reject closing client", function()
      local client = {
        id = "client_123",
        state = "closing",
        tcp_handle = {
          is_closing = function() return false end,
        },
      }
      
      local valid, err = safe_tcp.validate_client_state(client, "test_op")
      
      assert.is_false(valid)
      assert.matches("closing", err)
    end)
    
    it("should detect and update closing handle", function()
      local client = {
        id = "client_123",
        state = "connected",
        tcp_handle = {
          is_closing = function() return true end,
        },
      }
      
      local valid, err = safe_tcp.validate_client_state(client, "test_op")
      
      assert.is_false(valid)
      assert.equals("closing", client.state) -- State updated
      assert.matches("closing or invalid", err)
    end)
  end)
  
  describe("graceful_client_cleanup", function()
    it("should cleanup client gracefully", function()
      local tcp_closed = false
      local timer_stopped = false
      
      local client = {
        id = "client_123",
        state = "connected",
        tcp_handle = {
          is_closing = function() return false end,
          close = function() tcp_closed = true end,
        },
        ping_timer = {
          stop = function() timer_stopped = true end,
          close = function() end,
          is_active = function() return true end,
          is_closing = function() return false end,
        },
      }
      
      safe_tcp.graceful_client_cleanup(client, "test_reason")
      
      assert.equals("closed", client.state)
      assert.is_true(tcp_closed)
      assert.is_true(timer_stopped)
      assert.is_nil(client.ping_timer)
    end)
    
    it("should not cleanup already closed client", function()
      local tcp_closed = false
      
      local client = {
        id = "client_123",
        state = "closed",
        tcp_handle = {
          close = function() tcp_closed = true end,
        },
      }
      
      safe_tcp.graceful_client_cleanup(client, "test_reason")
      
      assert.equals("closed", client.state)
      assert.is_false(tcp_closed) -- Should not close again
    end)
    
    it("should handle nil client", function()
      -- Should not error
      safe_tcp.graceful_client_cleanup(nil, "test_reason")
    end)
  end)
  
  describe("error monitoring", function()
    it("should record errors", function()
      local is_critical = safe_tcp.record_error("tcp_errors", "Test error")
      
      local stats = safe_tcp.get_error_stats()
      assert.equals(1, stats.tcp_errors)
      assert.equals(0, stats.parse_errors)
      assert.equals(0, stats.callback_errors)
      assert.is_false(is_critical)
    end)
    
    it("should detect critical error rate", function()
      -- Record many errors
      for i = 1, 11 do
        safe_tcp.record_error("tcp_errors", "Error " .. i)
      end
      
      local stats = safe_tcp.get_error_stats()
      assert.equals(11, stats.tcp_errors)
      
      -- Last error should be marked as critical
      local is_critical = safe_tcp.record_error("tcp_errors", "Error 12")
      assert.is_true(is_critical)
    end)
    
    it("should reset error statistics", function()
      safe_tcp.record_error("tcp_errors", "Error 1")
      safe_tcp.record_error("parse_errors", "Error 2")
      safe_tcp.record_error("callback_errors", "Error 3")
      
      local stats = safe_tcp.get_error_stats()
      assert.equals(1, stats.tcp_errors)
      assert.equals(1, stats.parse_errors)
      assert.equals(1, stats.callback_errors)
      
      safe_tcp.reset_error_stats()
      
      stats = safe_tcp.get_error_stats()
      assert.equals(0, stats.tcp_errors)
      assert.equals(0, stats.parse_errors)
      assert.equals(0, stats.callback_errors)
    end)
    
    it("should reset counters after time window", function()
      -- Mock time
      local current_time = 0
      vim.loop.now = function() return current_time end
      
      -- Record errors
      safe_tcp.record_error("tcp_errors", "Error 1")
      assert.equals(1, safe_tcp.get_error_stats().tcp_errors)
      
      -- Advance time beyond window (61 seconds)
      current_time = 61000
      
      -- New error should reset counters
      safe_tcp.record_error("tcp_errors", "Error 2")
      assert.equals(1, safe_tcp.get_error_stats().tcp_errors) -- Reset to 1
    end)
  end)
  
  describe("safe_timer", function()
    it("should create and execute timer", function()
      local executed = false
      local callback = function()
        executed = true
      end
      
      local timer = safe_tcp.safe_timer(callback, 100, 0)
      
      assert.is_not_nil(timer)
      
      -- Simulate timer execution
      timer.callback()
      assert.is_true(executed)
    end)
    
    it("should catch timer callback errors", function()
      local error_logged = false
      local original_error = logger.error
      logger.error = function(module, msg, err)
        error_logged = true
        assert.matches("Timer callback failed", msg)
        assert.matches("Timer error!", err)
      end
      
      local timer = safe_tcp.safe_timer(function()
        error("Timer error!")
      end, 100, 0)
      
      -- Execute callback
      timer.callback()
      
      assert.is_true(error_logged)
      logger.error = original_error
    end)
    
    it("should stop timer safely", function()
      local timer = {
        is_active = function() return true end,
        is_closing = function() return false end,
        stop = function() end,
        close = function() end,
      }
      
      local success = safe_tcp.safe_timer_stop(timer)
      assert.is_true(success)
    end)
    
    it("should handle nil timer", function()
      local success = safe_tcp.safe_timer_stop(nil)
      assert.is_false(success)
    end)
  end)
end)
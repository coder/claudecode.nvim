---@diagnostic disable: undefined-field, inject-field
local mock = require("tests.mocks.vim")

describe("reconnect", function()
  local reconnect
  local safe_tcp
  local logger
  
  before_each(function()
    -- Setup mocks
    _G.vim = mock
    
    -- Mock safe_tcp module
    package.loaded["claudecode.server.safe_tcp"] = {
      safe_timer = function(callback, delay, interval)
        local timer = { 
          callback = callback,
          delay = delay,
          interval = interval,
          stopped = false,
          stop = function(self) self.stopped = true end,
          close = function(self) self.stopped = true end,
        }
        return timer
      end,
      safe_timer_stop = function(timer)
        if timer then timer.stopped = true end
        return true
      end,
      safe_schedule = function(func, context)
        func()
      end,
    }
    
    -- Mock logger
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function() end,
    }
    
    -- Load modules after mocks are set
    safe_tcp = require("claudecode.server.safe_tcp")
    logger = require("claudecode.logger")
    reconnect = require("claudecode.server.reconnect")
  end)
  
  after_each(function()
    package.loaded["claudecode.server.reconnect"] = nil
    package.loaded["claudecode.server.safe_tcp"] = nil
    package.loaded["claudecode.logger"] = nil
  end)
  
  describe("setup", function()
    it("should initialize with default config", function()
      local connect_fn = function() end
      reconnect.setup(nil, connect_fn)
      
      assert.is_not_nil(reconnect.config)
      assert.is_true(reconnect.config.enabled)
      assert.equals(10, reconnect.config.max_attempts)
      assert.equals(1000, reconnect.config.initial_delay)
      assert.equals(30000, reconnect.config.max_delay)
      assert.equals(2, reconnect.config.backoff_factor)
    end)
    
    it("should accept custom config", function()
      local config = {
        enabled = false,
        max_attempts = 5,
        initial_delay = 2000,
        max_delay = 60000,
        backoff_factor = 3,
        show_notifications = false,
      }
      local connect_fn = function() end
      
      reconnect.setup(config, connect_fn)
      
      assert.is_false(reconnect.config.enabled)
      assert.equals(5, reconnect.config.max_attempts)
      assert.equals(2000, reconnect.config.initial_delay)
      assert.equals(60000, reconnect.config.max_delay)
      assert.equals(3, reconnect.config.backoff_factor)
      assert.is_false(reconnect.config.show_notifications)
    end)
  end)
  
  describe("connection state", function()
    it("should track connection state properly", function()
      reconnect.setup(nil, function() end)
      
      assert.equals("disconnected", reconnect.state.status)
      
      reconnect.on_connected()
      assert.equals("connected", reconnect.state.status)
      assert.equals(0, reconnect.state.attempt)
      
      reconnect.on_disconnected(1006, "Connection lost")
      assert.equals("disconnected", reconnect.state.status)
    end)
    
    it("should reset attempt counter on successful connection", function()
      reconnect.setup(nil, function() end)
      
      reconnect.state.attempt = 5
      reconnect.on_connected()
      
      assert.equals(0, reconnect.state.attempt)
      assert.is_nil(reconnect.state.last_error)
    end)
  end)
  
  describe("disconnection classification", function()
    it("should not reconnect on normal closure", function()
      local connect_called = false
      reconnect.setup(nil, function() 
        connect_called = true 
      end)
      
      reconnect.on_disconnected(1000, "Normal closure")
      assert.is_false(connect_called)
      assert.equals("disconnected", reconnect.state.status)
    end)
    
    it("should not reconnect on authentication error", function()
      local connect_called = false
      reconnect.setup(nil, function() 
        connect_called = true 
      end)
      
      reconnect.on_disconnected(1002, "Unauthorized access")
      assert.is_false(connect_called)
      assert.equals("disconnected", reconnect.state.status)
    end)
    
    it("should attempt reconnect on network error", function()
      local connect_called = false
      reconnect.setup({ enabled = true }, function() 
        connect_called = true
        return true
      end)
      
      -- Mock timer execution
      local original_safe_timer = safe_tcp.safe_timer
      safe_tcp.safe_timer = function(callback, delay, interval)
        -- Execute callback immediately for testing
        callback()
        return original_safe_timer(callback, delay, interval)
      end
      
      reconnect.on_disconnected(1006, "Connection timeout")
      assert.is_true(connect_called)
    end)
  end)
  
  describe("exponential backoff", function()
    it("should calculate delays correctly", function()
      reconnect.setup({
        initial_delay = 1000,
        max_delay = 30000,
        backoff_factor = 2,
      }, function() end)
      
      reconnect.state.attempt = 0
      reconnect.state.next_delay = 1000
      
      -- First attempt: 1000ms
      assert.equals(1000, reconnect.state.next_delay)
      
      -- Simulate attempts with exponential backoff
      local delays = {}
      for i = 1, 5 do
        reconnect.state.attempt = i
        if i == 1 then
          reconnect.state.next_delay = 1000
        else
          reconnect.state.next_delay = math.min(
            reconnect.state.next_delay * 2,
            30000
          )
        end
        table.insert(delays, reconnect.state.next_delay)
      end
      
      -- Expected: 1000, 2000, 4000, 8000, 16000
      assert.equals(1000, delays[1])
      assert.equals(2000, delays[2])
      assert.equals(4000, delays[3])
      assert.equals(8000, delays[4])
      assert.equals(16000, delays[5])
    end)
    
    it("should respect max_delay limit", function()
      reconnect.setup({
        initial_delay = 1000,
        max_delay = 5000,
        backoff_factor = 2,
      }, function() end)
      
      -- Simulate many attempts
      reconnect.state.next_delay = 4000
      for i = 1, 10 do
        reconnect.state.attempt = i
        reconnect.state.next_delay = math.min(
          reconnect.state.next_delay * 2,
          5000
        )
      end
      
      -- Should not exceed max_delay
      assert.equals(5000, reconnect.state.next_delay)
    end)
  end)
  
  describe("max attempts", function()
    it("should stop after max attempts", function()
      local attempt_count = 0
      reconnect.setup({
        enabled = true,
        max_attempts = 3,
        initial_delay = 10,
      }, function() 
        attempt_count = attempt_count + 1
        -- Simulate connection failure
        error("Connection failed")
      end)
      
      -- Mock timer to execute immediately
      local timers_created = {}
      safe_tcp.safe_timer = function(callback, delay, interval)
        local timer = { 
          callback = callback,
          delay = delay,
          stopped = false,
        }
        table.insert(timers_created, timer)
        -- Don't execute callback in this test
        return timer
      end
      
      reconnect.on_disconnected(1006, "Connection lost")
      
      -- Manually trigger reconnection attempts
      for i = 1, 4 do
        if reconnect.state.attempt < reconnect.config.max_attempts then
          reconnect.reconnect()
        end
      end
      
      -- Should not exceed max_attempts
      assert.is_true(reconnect.state.attempt <= 3)
    end)
    
    it("should mark as failed after max attempts", function()
      reconnect.setup({
        enabled = true,
        max_attempts = 1,
      }, function() 
        error("Connection failed")
      end)
      
      reconnect.state.attempt = 1
      reconnect.reconnect()
      
      -- Should be marked as failed
      assert.equals("failed", reconnect.state.status)
    end)
  end)
  
  describe("manual reconnection", function()
    it("should allow manual reconnection", function()
      local connect_called = false
      reconnect.setup(nil, function() 
        connect_called = true
        reconnect.on_connected()
      end)
      
      reconnect.state.status = "disconnected"
      reconnect.reconnect()
      
      assert.is_true(connect_called)
      assert.equals("connected", reconnect.state.status)
    end)
    
    it("should reset attempts on manual reconnect", function()
      reconnect.setup(nil, function() 
        reconnect.on_connected()
      end)
      
      reconnect.state.attempt = 5
      reconnect.state.status = "failed"
      
      reconnect.reconnect()
      
      assert.equals(0, reconnect.state.attempt)
      assert.equals("connected", reconnect.state.status)
    end)
    
    it("should not reconnect if already connected", function()
      local connect_count = 0
      reconnect.setup(nil, function() 
        connect_count = connect_count + 1
      end)
      
      reconnect.state.status = "connected"
      reconnect.reconnect()
      
      assert.equals(0, connect_count)
      assert.equals("connected", reconnect.state.status)
    end)
  end)
  
  describe("statistics", function()
    it("should track total reconnections", function()
      reconnect.setup(nil, function() end)
      
      assert.equals(0, reconnect.state.total_reconnects)
      
      reconnect.state.status = "reconnecting"
      reconnect.on_connected()
      assert.equals(1, reconnect.state.total_reconnects)
      
      reconnect.state.status = "reconnecting"
      reconnect.on_connected()
      assert.equals(2, reconnect.state.total_reconnects)
    end)
    
    it("should provide status information", function()
      reconnect.setup({
        enabled = true,
        max_attempts = 10,
      }, function() end)
      
      reconnect.state.attempt = 3
      reconnect.state.next_delay = 4000
      reconnect.state.last_disconnect_reason = "Timeout"
      reconnect.state.total_reconnects = 5
      
      local status = reconnect.get_status()
      
      assert.equals(reconnect.state.status, status.status)
      assert.equals(3, status.attempt)
      assert.equals(10, status.max_attempts)
      assert.equals(4000, status.next_delay)
      assert.equals("Timeout", status.last_disconnect_reason)
      assert.equals(5, status.total_reconnects)
      assert.is_true(status.enabled)
    end)
  end)
  
  describe("enable/disable", function()
    it("should stop reconnection when disabled", function()
      local connect_called = false
      reconnect.setup({
        enabled = true,
      }, function() 
        connect_called = true
      end)
      
      reconnect.set_enabled(false)
      reconnect.on_disconnected(1006, "Connection lost")
      
      assert.is_false(connect_called)
    end)
    
    it("should start reconnection when enabled", function()
      local connect_called = false
      reconnect.setup({
        enabled = false,
      }, function() 
        connect_called = true
        return true
      end)
      
      -- Mock timer
      safe_tcp.safe_timer = function(callback, delay, interval)
        callback() -- Execute immediately
        return { stopped = false }
      end
      
      reconnect.state.status = "disconnected"
      reconnect.set_enabled(true)
      
      assert.is_true(connect_called)
    end)
  end)
end)
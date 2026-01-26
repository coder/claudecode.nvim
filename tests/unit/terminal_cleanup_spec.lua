---Tests for terminal cleanup functionality
---Ensures cleanup_all() properly kills Claude processes on Neovim exit

describe("terminal cleanup_all", function()
  local terminal
  local mock_vim

  -- Track calls to vim functions
  local jobstop_calls = {}
  local system_calls = {}

  before_each(function()
    -- Reset call tracking
    jobstop_calls = {}
    system_calls = {}

    -- Mock vim global
    mock_vim = {
      api = {
        nvim_buf_is_valid = function(bufnr)
          return bufnr and bufnr > 0
        end,
        nvim_buf_get_var = function(bufnr, var_name)
          if var_name == "terminal_job_id" then
            return bufnr * 10 -- Return a predictable job_id based on bufnr
          end
          error("Unknown variable: " .. var_name)
        end,
        nvim_echo = function() end, -- Suppress debug output
        nvim_create_augroup = function()
          return 1
        end,
        nvim_create_autocmd = function()
          return 1
        end,
        nvim_list_bufs = function()
          return {} -- Default: no buffers
        end,
        nvim_get_option_value = function()
          return ""
        end,
      },
      fn = {
        jobpid = function(job_id)
          -- Return a predictable PID based on job_id
          return job_id * 100
        end,
        jobstop = function(job_id)
          table.insert(jobstop_calls, job_id)
          return 1
        end,
        system = function(cmd)
          table.insert(system_calls, cmd)
          return ""
        end,
      },
      log = {
        levels = {
          DEBUG = 1,
          INFO = 2,
          WARN = 3,
          ERROR = 4,
        },
      },
      loop = {
        now = function()
          return 12345
        end,
      },
    }

    -- Install mock vim
    _G.vim = mock_vim

    -- Clear all relevant modules first
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.server.init"] = nil
    package.loaded["claudecode.terminal.osc_handler"] = nil
    package.loaded["claudecode.session"] = nil

    -- Mock logger
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function() end,
    }

    -- Mock server module (required by terminal.lua)
    package.loaded["claudecode.server.init"] = {
      state = { port = 12345 },
    }

    -- Mock osc_handler module (required by terminal.lua)
    package.loaded["claudecode.terminal.osc_handler"] = {
      setup_buffer_handler = function() end,
      cleanup_buffer_handler = function() end,
    }

    -- Mock session manager module (required by terminal.lua)
    package.loaded["claudecode.session"] = {
      ensure_session = function()
        return "session_1"
      end,
      get_session = function()
        return nil
      end,
      destroy_session = function() end,
      find_session_by_bufnr = function()
        return nil
      end,
      list_sessions = function()
        return {}
      end,
      get_session_count = function()
        return 0
      end,
      get_active_session_id = function()
        return nil
      end,
      set_active_session = function() end,
      update_terminal_info = function() end,
      update_session_name = function() end,
    }

    -- Clear global tracked PIDs
    _G._claudecode_tracked_pids = {}
    _G._claudecode_buffer_to_session = {}

    terminal = require("claudecode.terminal")
  end)

  it("should do nothing when no PIDs are tracked", function()
    terminal.cleanup_all()

    assert.are.same({}, jobstop_calls)
    assert.are.same({}, system_calls)
  end)

  it("should kill tracked PIDs", function()
    -- Track a PID
    terminal.track_terminal_pid(42)

    terminal.cleanup_all()

    -- Should have called jobstop with the job_id
    assert.are.same({ 42 }, jobstop_calls)

    -- Should have called system with pkill command using the PID (42 * 100 = 4200)
    assert.is_true(#system_calls >= 1)
    local found_pkill = false
    for _, cmd in ipairs(system_calls) do
      if cmd:match("pkill %-TERM %-P 4200") then
        found_pkill = true
      end
    end
    assert.is_true(found_pkill, "Expected pkill -TERM -P 4200 command")
  end)

  it("should kill multiple tracked PIDs", function()
    -- Track multiple PIDs
    terminal.track_terminal_pid(100)
    terminal.track_terminal_pid(200)
    terminal.track_terminal_pid(300)

    terminal.cleanup_all()

    -- Should have called jobstop for all jobs
    assert.are.equal(3, #jobstop_calls)

    -- Should have pkill commands for all PIDs (100*100=10000, 200*100=20000, 300*100=30000)
    local found_pids = { [10000] = false, [20000] = false, [30000] = false }
    for _, cmd in ipairs(system_calls) do
      for pid, _ in pairs(found_pids) do
        if cmd:match("pkill %-TERM %-P " .. pid) then
          found_pids[pid] = true
        end
      end
    end
    assert.is_true(found_pids[10000], "Expected pkill for PID 10000")
    assert.is_true(found_pids[20000], "Expected pkill for PID 20000")
    assert.is_true(found_pids[30000], "Expected pkill for PID 30000")
  end)

  it("should untrack PIDs when terminal exits normally", function()
    -- Track a PID
    terminal.track_terminal_pid(42)

    -- Simulate terminal exiting normally
    terminal.untrack_terminal_pid(42)

    -- Now cleanup should have nothing to do
    terminal.cleanup_all()

    assert.are.same({}, jobstop_calls)
    assert.are.same({}, system_calls)
  end)

  it("should handle jobpid failure gracefully", function()
    -- Make jobpid fail
    mock_vim.fn.jobpid = function()
      error("Job not found")
    end

    -- track_terminal_pid should not error when jobpid fails
    assert.has_no.errors(function()
      terminal.track_terminal_pid(42)
    end)

    -- cleanup_all should not error either
    assert.has_no.errors(function()
      terminal.cleanup_all()
    end)
  end)

  it("should handle jobpid returning invalid PID", function()
    -- Make jobpid return 0 (invalid)
    mock_vim.fn.jobpid = function()
      return 0
    end

    -- track_terminal_pid should handle invalid PID gracefully
    terminal.track_terminal_pid(42)

    -- cleanup_all should not have any PIDs to kill
    terminal.cleanup_all()

    -- No system calls since PID was invalid
    assert.are.same({}, system_calls)
  end)

  it("should clear tracked PIDs after cleanup", function()
    -- Track a PID
    terminal.track_terminal_pid(42)

    -- First cleanup should kill it
    terminal.cleanup_all()
    assert.are.equal(1, #jobstop_calls)

    -- Reset tracking
    jobstop_calls = {}
    system_calls = {}

    -- Second cleanup should have nothing to do
    terminal.cleanup_all()
    assert.are.same({}, jobstop_calls)
    assert.are.same({}, system_calls)
  end)

  describe("defense-in-depth PID recovery", function()
    it("should recover PIDs from session manager", function()
      -- Mock session manager with sessions containing terminal_jobid
      package.loaded["claudecode.session"] = {
        list_sessions = function()
          return {
            { id = "session_1", terminal_jobid = 100 },
            { id = "session_2", terminal_jobid = 200 },
          }
        end,
      }

      -- PIDs are not tracked initially
      terminal.cleanup_all()

      -- Should have recovered and killed both PIDs (100*100=10000, 200*100=20000)
      assert.are.equal(2, #jobstop_calls)

      local found_pids = { [10000] = false, [20000] = false }
      for _, cmd in ipairs(system_calls) do
        for pid, _ in pairs(found_pids) do
          if cmd:match("pkill %-TERM %-P " .. pid) then
            found_pids[pid] = true
          end
        end
      end
      assert.is_true(found_pids[10000], "Expected pkill for recovered PID 10000")
      assert.is_true(found_pids[20000], "Expected pkill for recovered PID 20000")
    end)

    it("should recover PIDs from terminal buffers", function()
      -- Mock nvim_list_bufs to return terminal buffers
      mock_vim.api.nvim_list_bufs = function()
        return { 1, 2, 3 }
      end

      -- Mock nvim_get_option_value for buftype
      mock_vim.api.nvim_get_option_value = function(opt, opts)
        if opt == "buftype" then
          -- Buffers 1 and 3 are terminals, buffer 2 is not
          if opts.buf == 1 or opts.buf == 3 then
            return "terminal"
          end
          return ""
        end
        return nil
      end

      -- Mock nvim_buf_get_var to return terminal_job_id
      mock_vim.api.nvim_buf_get_var = function(bufnr, var_name)
        if var_name == "terminal_job_id" then
          if bufnr == 1 then
            return 300
          end
          if bufnr == 3 then
            return 400
          end
        end
        error("Unknown variable: " .. var_name)
      end

      -- Mock session manager to return empty (no sessions)
      package.loaded["claudecode.session"] = {
        list_sessions = function()
          return {}
        end,
      }

      terminal.cleanup_all()

      -- Should have recovered PIDs from terminal buffers (300*100=30000, 400*100=40000)
      assert.are.equal(2, #jobstop_calls)

      local found_pids = { [30000] = false, [40000] = false }
      for _, cmd in ipairs(system_calls) do
        for pid, _ in pairs(found_pids) do
          if cmd:match("pkill %-TERM %-P " .. pid) then
            found_pids[pid] = true
          end
        end
      end
      assert.is_true(found_pids[30000], "Expected pkill for recovered PID 30000")
      assert.is_true(found_pids[40000], "Expected pkill for recovered PID 40000")
    end)

    it("should handle mixed tracked and recovered PIDs", function()
      -- Track one PID directly
      terminal.track_terminal_pid(42)

      -- Mock session manager with one additional session
      package.loaded["claudecode.session"] = {
        list_sessions = function()
          return {
            { id = "session_1", terminal_jobid = 100 },
          }
        end,
      }

      -- Mock nvim_list_bufs to return one terminal buffer
      mock_vim.api.nvim_list_bufs = function()
        return { 5 }
      end

      mock_vim.api.nvim_get_option_value = function(opt, opts)
        if opt == "buftype" and opts.buf == 5 then
          return "terminal"
        end
        return ""
      end

      -- Use different job_id for buffer to avoid duplicate
      local original_buf_get_var = mock_vim.api.nvim_buf_get_var
      mock_vim.api.nvim_buf_get_var = function(bufnr, var_name)
        if var_name == "terminal_job_id" and bufnr == 5 then
          return 200
        end
        return original_buf_get_var(bufnr, var_name)
      end

      terminal.cleanup_all()

      -- Should have killed all 3 PIDs:
      -- - 42 (tracked directly) -> PID 4200
      -- - 100 (from session) -> PID 10000
      -- - 200 (from buffer) -> PID 20000
      assert.are.equal(3, #jobstop_calls)

      local found_pids = { [4200] = false, [10000] = false, [20000] = false }
      for _, cmd in ipairs(system_calls) do
        for pid, _ in pairs(found_pids) do
          if cmd:match("pkill %-TERM %-P " .. pid) then
            found_pids[pid] = true
          end
        end
      end
      assert.is_true(found_pids[4200], "Expected pkill for tracked PID 4200")
      assert.is_true(found_pids[10000], "Expected pkill for session PID 10000")
      assert.is_true(found_pids[20000], "Expected pkill for buffer PID 20000")
    end)

    it("should not duplicate PIDs already tracked", function()
      -- Track a PID directly
      terminal.track_terminal_pid(42)

      -- Mock session manager to return the same job_id
      package.loaded["claudecode.session"] = {
        list_sessions = function()
          return {
            { id = "session_1", terminal_jobid = 42 }, -- Same as tracked
          }
        end,
      }

      -- Mock empty buffer list
      mock_vim.api.nvim_list_bufs = function()
        return {}
      end

      terminal.cleanup_all()

      -- Should only kill one PID (not duplicated)
      assert.are.equal(1, #jobstop_calls)
      assert.are.same({ 42 }, jobstop_calls)
    end)

    it("should handle session manager load failure gracefully", function()
      -- Make session manager require fail
      package.loaded["claudecode.session"] = nil
      package.preload["claudecode.session"] = function()
        error("Module not found")
      end

      -- Track a PID to verify cleanup still works
      terminal.track_terminal_pid(42)

      -- Should not error
      assert.has_no.errors(function()
        terminal.cleanup_all()
      end)

      -- Should still kill tracked PID
      assert.are.equal(1, #jobstop_calls)

      -- Cleanup preload
      package.preload["claudecode.session"] = nil
    end)

    it("should handle buffer iteration failure gracefully", function()
      -- Make nvim_list_bufs fail
      mock_vim.api.nvim_list_bufs = function()
        error("API error")
      end

      -- Track a PID to verify cleanup still works
      terminal.track_terminal_pid(42)

      -- Should not error
      assert.has_no.errors(function()
        terminal.cleanup_all()
      end)

      -- Should still kill tracked PID
      assert.are.equal(1, #jobstop_calls)
    end)
  end)
end)

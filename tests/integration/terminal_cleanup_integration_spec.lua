---Integration tests for terminal cleanup functionality
---These tests spawn REAL processes and verify they are killed on cleanup
---Unlike unit tests, these don't use mocks and test actual behavior

describe("terminal cleanup integration", function()
  local terminal

  -- Helper to check if a process exists
  local function process_exists(pid)
    if not pid or pid <= 0 then
      return false
    end
    -- kill -0 checks if process exists without killing it
    local result = os.execute("kill -0 " .. pid .. " 2>/dev/null")
    -- os.execute returns true/0 on success in Lua 5.1+
    return result == true or result == 0
  end

  -- Helper to spawn a test process and return its job_id
  local function spawn_test_process()
    -- Spawn a simple sleep process that will run for a while
    local job_id = vim.fn.jobstart({ "sleep", "300" }, {
      detach = false,
      on_exit = function() end,
    })
    return job_id
  end

  -- Helper to get PID from job_id
  local function get_pid(job_id)
    local ok, pid = pcall(vim.fn.jobpid, job_id)
    if ok and pid and pid > 0 then
      return pid
    end
    return nil
  end

  -- Helper to wait for process to die (with timeout)
  local function wait_for_process_death(pid, timeout_ms)
    timeout_ms = timeout_ms or 2000
    local start = vim.loop.now()
    while vim.loop.now() - start < timeout_ms do
      if not process_exists(pid) then
        return true
      end
      -- Small delay
      vim.loop.sleep(50)
    end
    return false
  end

  before_each(function()
    -- Clear any existing tracked PIDs
    _G._claudecode_tracked_pids = {}
    _G._claudecode_buffer_to_session = {}

    -- Reload terminal module fresh
    package.loaded["claudecode.terminal"] = nil
    terminal = require("claudecode.terminal")
  end)

  after_each(function()
    -- Ensure cleanup runs after each test
    if terminal and terminal.cleanup_all then
      pcall(terminal.cleanup_all)
    end
  end)

  describe("cleanup_all with real processes", function()
    it("should kill a single tracked process", function()
      -- Spawn a real process
      local job_id = spawn_test_process()
      assert.is_truthy(job_id, "Failed to spawn test process")
      assert.is_true(job_id > 0, "Invalid job_id")

      -- Get its PID
      local pid = get_pid(job_id)
      assert.is_truthy(pid, "Failed to get PID from job_id")

      -- Verify process is running
      assert.is_true(process_exists(pid), "Process should be running before cleanup")

      -- Track it
      terminal.track_terminal_pid(job_id)

      -- Run cleanup
      terminal.cleanup_all()

      -- Verify process is dead (give it some time)
      local died = wait_for_process_death(pid, 2000)
      assert.is_true(died, "Process " .. pid .. " should have been killed by cleanup_all")
    end)

    it("should kill multiple tracked processes", function()
      local jobs = {}
      local pids = {}

      -- Spawn 3 processes
      for i = 1, 3 do
        local job_id = spawn_test_process()
        assert.is_truthy(job_id, "Failed to spawn test process " .. i)

        local pid = get_pid(job_id)
        assert.is_truthy(pid, "Failed to get PID for job " .. i)

        -- Verify running
        assert.is_true(process_exists(pid), "Process " .. i .. " should be running")

        -- Track it
        terminal.track_terminal_pid(job_id)

        table.insert(jobs, job_id)
        table.insert(pids, pid)
      end

      -- Run cleanup
      terminal.cleanup_all()

      -- Verify all processes are dead
      for i, pid in ipairs(pids) do
        local died = wait_for_process_death(pid, 2000)
        assert.is_true(died, "Process " .. i .. " (PID " .. pid .. ") should have been killed")
      end
    end)

    it("should kill child processes of tracked shells", function()
      -- Spawn a shell that itself spawns a child process
      -- This tests the pkill -P behavior
      local job_id = vim.fn.jobstart({ "sh", "-c", "sleep 300 & sleep 300" }, {
        detach = false,
        on_exit = function() end,
      })
      assert.is_truthy(job_id, "Failed to spawn shell")

      local shell_pid = get_pid(job_id)
      assert.is_truthy(shell_pid, "Failed to get shell PID")

      -- Give the shell time to spawn its children
      vim.loop.sleep(200)

      -- Find child PIDs using pgrep
      local handle = io.popen("pgrep -P " .. shell_pid .. " 2>/dev/null")
      local child_pids_str = handle:read("*a")
      handle:close()

      local child_pids = {}
      for pid_str in child_pids_str:gmatch("%d+") do
        table.insert(child_pids, tonumber(pid_str))
      end

      -- Track the shell
      terminal.track_terminal_pid(job_id)

      -- Verify shell and children are running
      assert.is_true(process_exists(shell_pid), "Shell should be running before cleanup")
      for _, child_pid in ipairs(child_pids) do
        assert.is_true(process_exists(child_pid), "Child " .. child_pid .. " should be running before cleanup")
      end

      -- Run cleanup
      terminal.cleanup_all()

      -- Verify shell is dead
      local shell_died = wait_for_process_death(shell_pid, 2000)
      assert.is_true(shell_died, "Shell process should have been killed")

      -- Verify children are dead
      for _, child_pid in ipairs(child_pids) do
        local child_died = wait_for_process_death(child_pid, 2000)
        assert.is_true(child_died, "Child process " .. child_pid .. " should have been killed")
      end
    end)

    it("should handle untracked processes gracefully", function()
      -- Spawn a process but DON'T track it
      local job_id = spawn_test_process()
      local pid = get_pid(job_id)
      assert.is_truthy(pid, "Failed to get PID")

      -- Verify running
      assert.is_true(process_exists(pid), "Process should be running")

      -- Run cleanup (nothing tracked)
      terminal.cleanup_all()

      -- Process should still be running (we didn't track it)
      assert.is_true(process_exists(pid), "Untracked process should NOT be killed")

      -- Cleanup: kill it manually
      pcall(vim.fn.jobstop, job_id)
    end)

    it("should clear tracking after cleanup", function()
      -- Spawn and track a process
      local job_id = spawn_test_process()
      terminal.track_terminal_pid(job_id)

      -- First cleanup
      terminal.cleanup_all()

      -- Spawn another process
      local job_id2 = spawn_test_process()
      local pid2 = get_pid(job_id2)

      -- DON'T track it

      -- Second cleanup should not affect untracked process
      terminal.cleanup_all()

      -- Process 2 should still be running
      assert.is_true(process_exists(pid2), "Untracked process should survive cleanup")

      -- Cleanup
      pcall(vim.fn.jobstop, job_id2)
    end)
  end)

  describe("defense-in-depth recovery with real processes", function()
    it("should recover and kill processes from terminal buffers", function()
      -- Create a real terminal buffer with a process
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("buftype", "terminal", { buf = buf })

      -- Start a terminal job in this buffer
      vim.api.nvim_buf_call(buf, function()
        vim.fn.termopen("sleep 300", {
          on_exit = function() end,
        })
      end)

      -- Get the job_id from the buffer
      local ok, job_id = pcall(vim.api.nvim_buf_get_var, buf, "terminal_job_id")
      assert.is_true(ok, "Should have terminal_job_id")
      assert.is_truthy(job_id, "Job ID should be set")

      local pid = get_pid(job_id)
      assert.is_truthy(pid, "Should have valid PID")
      assert.is_true(process_exists(pid), "Process should be running")

      -- DON'T track it via track_terminal_pid - let defense-in-depth find it

      -- Run cleanup - should recover PID from buffer
      terminal.cleanup_all()

      -- Process should be dead
      local died = wait_for_process_death(pid, 2000)
      assert.is_true(died, "Process should have been killed via defense-in-depth recovery")

      -- Cleanup buffer
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
  end)
end)

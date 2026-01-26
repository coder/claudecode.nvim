---Real integration test for terminal cleanup
---Run with: nvim --headless -u tests/minimal_init.lua -c "luafile tests/integration/test_cleanup_real.lua"

local function log(msg)
  print("[TEST] " .. msg)
end

local function process_exists(pid)
  if not pid or pid <= 0 then
    return false
  end
  local result = os.execute("kill -0 " .. pid .. " 2>/dev/null")
  return result == true or result == 0
end

local function wait_for_death(pid, timeout_ms)
  timeout_ms = timeout_ms or 2000
  local start = vim.loop.now()
  local iterations = 0
  while vim.loop.now() - start < timeout_ms do
    if not process_exists(pid) then
      return true
    end
    iterations = iterations + 1
    -- Use vim.wait instead of vim.loop.sleep for better compatibility
    vim.wait(50, function()
      return false
    end)
    if iterations > 100 then
      -- Safety: don't loop forever
      break
    end
  end
  return not process_exists(pid)
end

local function test_single_process_cleanup()
  log("=== Test: Single process cleanup ===")

  -- Clear tracking
  _G._claudecode_tracked_pids = {}
  package.loaded["claudecode.terminal"] = nil
  local terminal = require("claudecode.terminal")

  -- Spawn a process
  local job_id = vim.fn.jobstart({ "sleep", "300" }, { detach = false })
  if not job_id or job_id <= 0 then
    log("FAIL: Could not spawn process")
    return false
  end

  local pid = vim.fn.jobpid(job_id)
  log("Spawned process: job_id=" .. job_id .. ", pid=" .. pid)

  if not process_exists(pid) then
    log("FAIL: Process not running after spawn")
    return false
  end

  -- Track it
  terminal.track_terminal_pid(job_id)
  log("Tracked PID")

  -- Cleanup
  terminal.cleanup_all()
  log("Called cleanup_all()")

  -- Verify death
  if wait_for_death(pid, 2000) then
    log("PASS: Process was killed")
    return true
  else
    log("FAIL: Process still running after cleanup")
    vim.fn.jobstop(job_id) -- Manual cleanup
    return false
  end
end

local function test_multiple_processes_cleanup()
  log("=== Test: Multiple processes cleanup ===")

  _G._claudecode_tracked_pids = {}
  package.loaded["claudecode.terminal"] = nil
  local terminal = require("claudecode.terminal")

  local pids = {}
  local jobs = {}

  -- Spawn 3 processes
  for i = 1, 3 do
    local job_id = vim.fn.jobstart({ "sleep", "300" }, { detach = false })
    if not job_id or job_id <= 0 then
      log("FAIL: Could not spawn process " .. i)
      return false
    end

    local pid = vim.fn.jobpid(job_id)
    terminal.track_terminal_pid(job_id)

    table.insert(jobs, job_id)
    table.insert(pids, pid)
    log("Spawned process " .. i .. ": pid=" .. pid)
  end

  -- Cleanup
  terminal.cleanup_all()
  log("Called cleanup_all()")

  -- Verify all dead
  local all_dead = true
  for i, pid in ipairs(pids) do
    if wait_for_death(pid, 2000) then
      log("Process " .. i .. " (pid=" .. pid .. "): KILLED")
    else
      log("Process " .. i .. " (pid=" .. pid .. "): STILL RUNNING - FAIL")
      all_dead = false
      vim.fn.jobstop(jobs[i])
    end
  end

  if all_dead then
    log("PASS: All processes killed")
    return true
  else
    log("FAIL: Some processes survived")
    return false
  end
end

local function test_child_process_cleanup()
  log("=== Test: Child process cleanup (pkill -P) ===")

  _G._claudecode_tracked_pids = {}
  package.loaded["claudecode.terminal"] = nil
  local terminal = require("claudecode.terminal")

  -- Spawn shell with child processes
  local job_id = vim.fn.jobstart({ "sh", "-c", "sleep 300 & sleep 300 & wait" }, { detach = false })
  if not job_id or job_id <= 0 then
    log("FAIL: Could not spawn shell")
    return false
  end

  local shell_pid = vim.fn.jobpid(job_id)
  log("Shell pid=" .. shell_pid)

  -- Wait for children to spawn
  vim.loop.sleep(200)

  -- Find children
  local handle = io.popen("pgrep -P " .. shell_pid .. " 2>/dev/null")
  local children_str = handle:read("*a")
  handle:close()

  local child_pids = {}
  for pid_str in children_str:gmatch("%d+") do
    table.insert(child_pids, tonumber(pid_str))
  end
  log("Found " .. #child_pids .. " children: " .. children_str:gsub("\n", ", "))

  -- Track shell
  terminal.track_terminal_pid(job_id)

  -- Cleanup
  terminal.cleanup_all()
  log("Called cleanup_all()")

  -- Verify shell dead
  local shell_dead = wait_for_death(shell_pid, 2000)
  if shell_dead then
    log("Shell (pid=" .. shell_pid .. "): KILLED")
  else
    log("Shell (pid=" .. shell_pid .. "): STILL RUNNING - FAIL")
  end

  -- Verify children dead
  local all_children_dead = true
  for _, child_pid in ipairs(child_pids) do
    if wait_for_death(child_pid, 2000) then
      log("Child (pid=" .. child_pid .. "): KILLED")
    else
      log("Child (pid=" .. child_pid .. "): STILL RUNNING - FAIL")
      all_children_dead = false
      pcall(function()
        os.execute("kill -9 " .. child_pid .. " 2>/dev/null")
      end)
    end
  end

  if shell_dead and all_children_dead then
    log("PASS: Shell and all children killed")
    return true
  else
    log("FAIL: Some processes survived")
    vim.fn.jobstop(job_id)
    return false
  end
end

local function test_defense_in_depth()
  log("=== Test: Defense-in-depth (untracked terminal buffer) ===")

  _G._claudecode_tracked_pids = {}
  package.loaded["claudecode.terminal"] = nil
  local terminal = require("claudecode.terminal")

  -- Create a real terminal buffer using termopen
  local buf = vim.api.nvim_create_buf(false, true)

  -- Start terminal in buffer using termopen (this sets buftype automatically)
  local job_id
  vim.api.nvim_buf_call(buf, function()
    job_id = vim.fn.termopen("sleep 300", {
      on_exit = function() end,
    })
  end)

  if not job_id or job_id <= 0 then
    log("FAIL: Could not start terminal")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return false
  end

  local pid = vim.fn.jobpid(job_id)
  log("Terminal: job_id=" .. job_id .. ", pid=" .. pid)

  -- Verify it's a terminal buffer
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
  log("Buffer type: " .. buftype)

  if buftype ~= "terminal" then
    log("FAIL: Buffer is not a terminal")
    vim.fn.jobstop(job_id)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return false
  end

  -- DON'T track it - let defense-in-depth find it
  log("NOT tracking PID - testing defense-in-depth recovery")

  -- Cleanup should find it via buffer scan
  terminal.cleanup_all()
  log("Called cleanup_all()")

  -- Verify death
  if wait_for_death(pid, 2000) then
    log("PASS: Untracked terminal process was killed via defense-in-depth")
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return true
  else
    log("FAIL: Untracked process survived - defense-in-depth didn't work")
    vim.fn.jobstop(job_id)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return false
  end
end

-- Run all tests
log("========================================")
log("Starting Terminal Cleanup Integration Tests")
log("========================================")

local results = {}
table.insert(results, { "Single process", test_single_process_cleanup() })
table.insert(results, { "Multiple processes", test_multiple_processes_cleanup() })
table.insert(results, { "Child processes", test_child_process_cleanup() })
table.insert(results, { "Defense-in-depth", test_defense_in_depth() })

log("========================================")
log("RESULTS:")
log("========================================")

local all_passed = true
for _, r in ipairs(results) do
  local status = r[2] and "PASS" or "FAIL"
  log(r[1] .. ": " .. status)
  if not r[2] then
    all_passed = false
  end
end

log("========================================")
if all_passed then
  log("ALL TESTS PASSED")
  vim.cmd("qa!")
else
  log("SOME TESTS FAILED")
  vim.cmd("cq!") -- Exit with error code
end

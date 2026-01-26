-- Quick verification that processes are created and terminated
local function process_exists(pid)
  local result = os.execute("kill -0 " .. pid .. " 2>/dev/null")
  return result == true or result == 0
end

print("=== VERIFICATION TEST ===")

-- 1. Spawn 3 processes
print("\n1. Spawning 3 processes...")
local jobs = {}
local pids = {}
for i = 1, 3 do
  local job_id = vim.fn.jobstart({ "sleep", "300" }, { detach = false })
  local pid = vim.fn.jobpid(job_id)
  jobs[i] = job_id
  pids[i] = pid
  print("   Process " .. i .. ": job_id=" .. job_id .. ", pid=" .. pid)
end

-- 2. Verify they're running
print("\n2. Checking processes are running...")
for i, pid in ipairs(pids) do
  local exists = process_exists(pid)
  print("   PID " .. pid .. ": " .. (exists and "RUNNING ✓" or "NOT FOUND ✗"))
end

-- 3. Show in ps
print("\n3. Listing sleep processes (ps):")
os.execute('ps aux | grep "sleep 300" | grep -v grep')

-- 4. Track them
print("\n4. Tracking PIDs in terminal module...")
_G._claudecode_tracked_pids = {}
package.loaded["claudecode.terminal"] = nil
local terminal = require("claudecode.terminal")
for _, job_id in ipairs(jobs) do
  terminal.track_terminal_pid(job_id)
end
print("   Tracked " .. #jobs .. " jobs")

-- 5. Call cleanup_all
print("\n5. Calling cleanup_all()...")
terminal.cleanup_all()
print("   Done")

-- 6. Wait a moment
vim.wait(500, function()
  return false
end)

-- 7. Verify they're dead
print("\n6. Checking processes are DEAD...")
local all_dead = true
for i, pid in ipairs(pids) do
  local exists = process_exists(pid)
  print("   PID " .. pid .. ": " .. (exists and "STILL RUNNING ✗" or "DEAD ✓"))
  if exists then
    all_dead = false
  end
end

-- 8. Show in ps again
print("\n7. Listing sleep processes (ps) - should be empty:")
os.execute('ps aux | grep "sleep 300" | grep -v grep')

print("\n========================================")
if all_dead then
  print("SUCCESS: All processes terminated!")
else
  print("FAILURE: Some processes survived!")
end
print("========================================")

vim.cmd("qa!")

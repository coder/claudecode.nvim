--- Wraps `vim.fn.termopen` so that it returns only once the job's child has run exec. Neovim forks a pty job's child
--- with its own signal handlers and resets them a few system calls after the fork. A hangup in that window runs libuv's
--- handler in the child. That handler writes into the signal pipe that the child shares with Neovim, so Neovim reads a
--- SIGHUP of its own and exits ("Caught deadly signal 'SIGHUP'"). A job that a spec closes soon after termopen can hit
--- it. After exec the child has no handler of Neovim's. Until exec the child's executable and its command line are
--- Neovim's own. A job that runs Neovim again has another command line, except one that repeats the command line of
--- the test Neovim: termopen raises for it after 10 s. This needs /proc (Linux). Without it the window stays open.
--- A TermOpen autocmd runs inside termopen, before this wait, so a job that it stops stays outside the wrapper. The
--- autocmd can also stop the job or wipe its buffer, and jobpid then raises.

local function read_proc(pid, name)
  local file = io.open("/proc/" .. pid .. "/" .. name, "rb")
  local text = file and file:read("*a")
  if file then
    file:close()
  end
  return text
end

---@param real_termopen function
---@param api? table Stand-ins for `readlink(path)`, `read(pid, name)`, `jobpid(job)`, `hrtime()` and `sleep(ms)`
---@return function termopen
return function(real_termopen, api)
  local procs = vim.tbl_extend("force", {
    readlink = vim.loop.fs_readlink,
    read = read_proc,
    jobpid = vim.fn.jobpid,
    hrtime = vim.loop.hrtime,
    sleep = vim.loop.sleep,
  }, api or {})
  local self_exe = procs.readlink("/proc/self/exe")
  local self_cmdline = procs.read("self", "cmdline")

  return function(...)
    local job = real_termopen(...)
    local ok, pid = pcall(procs.jobpid, job)
    if self_exe and self_cmdline and ok then
      local deadline = procs.hrtime() + 10e9
      while procs.readlink("/proc/" .. pid .. "/exe") == self_exe and procs.read(pid, "cmdline") == self_cmdline do
        assert(procs.hrtime() < deadline, "the terminal job's child did not run exec within 10 s")
        procs.sleep(1)
      end
    end
    return job
  end
end

---Finds the Claude terminal buffers that a provider started, also after a plugin reload.
---A reload clears the provider modules and the terminal they track, but a buffer variable stays on the buffer.
---Each provider marks the buffer of its Claude when it starts it, and looks for it again when it tracks none.
---@module 'claudecode.terminal.owned'

local M = {}

---Buffer variable on a terminal buffer that the native provider started.
M.NATIVE_MARK = "claudecode_native_terminal"
---Buffer variable on a terminal buffer that the snacks provider started.
M.SNACKS_MARK = "claudecode_snacks_terminal"

-- A marked buffer has no job until termopen runs, and keeps its mark after the job exits. jobpid raises for a job
-- that exited or was stopped. jobwait({ id }, 0) would instead block until a stopped job exits.
---@param buf number
---@return boolean
function M.job_ended(buf)
  local channel = vim.bo[buf].channel
  return channel ~= 0 and not pcall(vim.fn.jobpid, channel)
end

-- The name of a process, or nil when it is gone or its name cannot be read. Linux has it in /proc, a read of a few bytes.
-- Where /proc is missing (macOS, the BSDs), nvim_get_proc asks `ps`, which takes ~100 ms and raises when `ps` is missing.
local function process_name(pid)
  local own = io.open("/proc/self/comm", "r")
  if own then
    own:close()
    local file = io.open("/proc/" .. pid .. "/comm", "r")
    if not file then
      return nil
    end
    local name = file:read("*l")
    file:close()
    return name
  end
  local ok, info = pcall(vim.api.nvim_get_proc, pid)
  return ok and info and info.name or nil
end

-- A stop looks at the child of a job that started less than this long ago (10 s).
local YOUNG_JOB_NS = 10 * 1e9

---Whether a job that started at `started_at` (`vim.loop.hrtime()`) is young enough that its child may not have run exec.
---@param started_at number|nil
---@return boolean
function M.is_young(started_at)
  return started_at ~= nil and vim.loop.hrtime() - started_at < YOUNG_JOB_NS
end

---Waits (up to 1 s) until the child of a pty job has run exec. A job that was just started can still be a fork of
---Neovim: its child has not run exec yet. A jobstop then ends Neovim (SIGHUP), or the buffer delete after it hangs.
---After the exec the child has the name of its command. A job that already exited has no pid. When the names cannot
---be read, this returns at once and the caller goes on to jobstop. The wait runs scheduled callbacks.
---@param jobid number
function M.wait_for_exec(jobid)
  local has_pid, child_pid = pcall(vim.fn.jobpid, jobid)
  local own_name = has_pid and process_name(vim.fn.getpid())
  if own_name then
    vim.wait(1000, function()
      local child_name = process_name(child_pid)
      return child_name == nil or child_name ~= own_name
    end, 5)
  end
end

---Whether the buffer carries the mark and its job has not ended.
---@param buf number
---@param mark string
---@return boolean
function M.is_live(buf, mark)
  return vim.api.nvim_buf_is_valid(buf) and vim.b[buf][mark] and not M.job_ended(buf) or false
end

---Finds a buffer that carries the mark and whose job has not ended, whether or not a window shows it.
---@param mark string
---@return number|nil buf
function M.find(mark)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if M.is_live(buf, mark) then
      return buf
    end
  end
  return nil
end

-- Stops the job in a marked buffer and deletes the buffer, without the provider that started it. Deleting a terminal
-- buffer while a write to its job is pending hangs Neovim (neovim/neovim#42508), so the delete waits for TermClose.
---@param buf number
---@param mark string
---@return boolean stopped whether the buffer is gone
local function stop_buffer(buf, mark)
  -- A provider reports a job that exits with an error, unless its mark is gone: this stop causes the exit.
  vim.b[buf][mark] = nil
  local exited = false
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf,
    once = true,
    callback = function()
      exited = true
    end,
  })
  -- The start time of this job is unknown here, so the child may be a fork of Neovim that has not run exec. The wait
  -- runs scheduled callbacks, and one of them can delete the buffer.
  local channel = vim.bo[buf].channel
  M.wait_for_exec(channel)
  if vim.api.nvim_buf_is_valid(buf) and vim.fn.jobstop(channel) == 1 then
    -- A user's TermClose autocmd can delete the buffer first, and that also removes this buffer-local autocmd.
    vim.wait(1000, function()
      return exited or not vim.api.nvim_buf_is_valid(buf)
    end, 10)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  return not vim.api.nvim_buf_is_valid(buf)
end

---Stops every live Claude that the other built-in provider marked. After a reload the provider choice can differ
---from the one that started that Claude, and the provider in use cannot control it.
---The other provider stops its own Claude quietly, when its module loads and still finds the terminal. Otherwise, and
---for what it leaves running, the marked buffer is stopped and deleted here.
---@param mark string The other provider's mark
---@param provider_name string The other provider's module name under claudecode.terminal
---@return boolean stopped true when a live Claude was found and every one is gone
function M.stop_other(mark, provider_name)
  if not M.find(mark) then
    return false
  end
  local ok, provider = pcall(require, "claudecode.terminal." .. provider_name)
  if ok and provider.is_available() then
    provider.close()
  end
  local buf = M.find(mark)
  while buf do
    if not stop_buffer(buf, mark) then
      require("claudecode.logger").error(
        "terminal",
        "Could not stop the Claude that the " .. provider_name .. " provider started."
      )
      return false
    end
    buf = M.find(mark)
  end
  return true
end

return M

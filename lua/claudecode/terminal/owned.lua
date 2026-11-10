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

return M

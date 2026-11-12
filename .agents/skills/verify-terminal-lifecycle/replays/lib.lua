-- Helpers shared by the replays. Each replay prints one line per step and ends with a count line.
local M = {}

M.results = {}

-- Print one step. `bug` marks the line that shows the finding.
function M.step(text, bug)
  -- Not print: in a headless Neovim a message gets its line end only with the next message, and a redraw in between
  -- (a key typed in a terminal window, for one) joins two lines.
  io.stdout:write((bug and "BUG  " or "     ") .. text .. "\n")
  io.stdout:flush()
  if bug ~= nil then
    table.insert(M.results, bug)
  end
end

-- Terminal buffers whose job still runs.
function M.running()
  local running = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
      local chan = vim.bo[buf].channel
      if chan ~= 0 and pcall(vim.fn.jobpid, chan) then
        table.insert(running, buf)
      end
    end
  end
  return running
end

-- Run one scenario of a replay. When the plugin's state is not what the scenario expects (a window that the next step needs
-- is gone), the scenario stops with a BUG line instead of an error that would leave Neovim running, and the replay goes on.
function M.attempt(label, body)
  local ok, err = pcall(body)
  if not ok then
    M.step(label .. ": the scenario stopped: " .. tostring(err):gsub("\n.*", ""), true)
  end
end

function M.windows_showing(buf)
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      count = count + 1
    end
  end
  return count
end

function M.wait(ms)
  vim.wait(ms, function()
    return false
  end, 10)
end

-- Let the job start and print its first output.
function M.settle()
  M.wait(300)
end

-- Clear every claudecode module and run the terminal setup again, as `:Lazy reload claudecode.nvim` does.
function M.reload(setup)
  for name in pairs(package.loaded) do
    if name:match("^claudecode") then
      package.loaded[name] = nil
    end
  end
  return setup()
end

-- Print the count line, stop every job, and quit.
function M.finish()
  local bugs = 0
  for _, bug in ipairs(M.results) do
    if bug then
      bugs = bugs + 1
    end
  end
  io.stdout:write(string.format("checks: %d, showing the finding: %d\n", #M.results, bugs))
  io.stdout:flush()
  for _, buf in ipairs(M.running()) do
    pcall(vim.fn.jobstop, vim.bo[buf].channel)
  end
  -- `:qa!` exits with 0, so a finding quits with `:cquit`, which sets the exit code that run.sh reports.
  pcall(vim.cmd, bugs > 0 and "cquit 1" or "qa!")
  -- After a reload, Snacks' ExitPre handlers of the old instances can keep the quit from taking effect in a headless Neovim.
  os.exit(bugs > 0 and 1 or 0)
end

return M

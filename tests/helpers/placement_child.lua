-- Runs one scenario in a headless Neovim for the placement specs, and reads the result that the scenario wrote. Each
-- scenario has its own Neovim, so a crash or a hang fails one case, with its exit code, and not the whole file.
local M = {}

-- Every scenario script starts with this. `P` holds the parameters of the case, `result` is what the case reports.
M.PRELUDE = [==[
local P = vim.json.decode(os.getenv("CASE") or "{}")
vim.o.swapfile = false
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "alpha", "beta" }, dir .. "/a.txt")
vim.fn.writefile({ "b1", "b2" }, dir .. "/b.txt")
vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
local file, original = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local first_tab = vim.api.nvim_get_current_tabpage()
local result = {}
local function finish()
  vim.fn.writefile({ vim.json.encode(result) }, os.getenv("CONTRACT_OUT"))
  vim.cmd("qa!")
end
vim.defer_fn(function()
  result.timeout = true
  finish()
end, 15000)
local function setup_native()
  require("claudecode").setup({
    auto_start = false,
    log_level = "error",
    terminal_cmd = "sleep 3600",
    terminal = { provider = "native", auto_insert = false },
  })
  return require("claudecode.terminal")
end
local labels = {}
local function buf_label(buf)
  if buf == file then
    return "A"
  end
  if labels[buf] then
    return labels[buf]
  end
  if vim.api.nvim_buf_is_valid(buf) and (vim.b[buf].claudecode_native_terminal or vim.bo[buf].buftype == "terminal") then
    return "T"
  end
  return "#" .. buf
end
local function win_label(win)
  if win == original then
    return "O"
  end
  return vim.api.nvim_win_get_tabpage(win) == first_tab and "S" or "N"
end
local events = {}
local function record_events()
  vim.api.nvim_create_autocmd(
    { "BufLeave", "BufWinLeave", "BufHidden", "BufUnload", "BufEnter", "BufWinEnter", "WinEnter", "WinLeave" },
    {
      callback = function(ev)
        events[#events + 1] = ev.event .. ":" .. buf_label(ev.buf) .. ":" .. win_label(vim.api.nvim_get_current_win())
      end,
    }
  )
end
local function hide_terminal(terminal)
  for _, win in ipairs(vim.fn.win_findbuf(terminal.get_active_terminal_bufnr())) do
    vim.api.nvim_win_close(win, false)
  end
end
]==]

---Runs the scenario script `body` with the parameters `case` in a headless Neovim. Returns its exit code (nil after a
---hang of 30 s) and the result it wrote.
---@param body string
---@param case? table
---@return number? exit_code
---@return table? result
function M.run_case(body, case)
  local script_file, out = vim.fn.tempname() .. ".lua", vim.fn.tempname()
  vim.fn.writefile(vim.split(M.PRELUDE .. body, "\n"), script_file)
  local exit_code
  local job = vim.fn.jobstart({
    vim.v.progpath,
    "--headless",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-n",
    "--cmd",
    "set rtp^=" .. vim.fn.getcwd(),
    "-c",
    "luafile " .. vim.fn.fnameescape(script_file),
  }, {
    env = { CASE = vim.json.encode(case or {}), CONTRACT_OUT = out },
    on_exit = function(_, code)
      exit_code = code
    end,
  })
  assert.is_true(job > 0, "could not start a child Neovim")
  if not vim.wait(30000, function()
    return exit_code ~= nil
  end, 50) then
    vim.fn.jobstop(job)
  end
  local result
  if vim.fn.filereadable(out) == 1 then
    result = vim.json.decode(table.concat(vim.fn.readfile(out), "\n"))
  end
  vim.fn.delete(script_file)
  vim.fn.delete(out)
  return exit_code, result
end

---The result of a case that ran to its end: Neovim exited 0, wrote a result, and its watchdog did not fire.
---@param body string
---@param case? table
---@return table result
function M.run_to_end(body, case)
  local exit_code, result = M.run_case(body, case)
  assert.equal(0, exit_code, "Neovim must survive (nil is a hang): " .. vim.inspect(result))
  assert.is_not_nil(result, "the case wrote no result")
  assert.is_nil(result.timeout, "the case did not finish: " .. vim.inspect(result))
  return result
end

return M

-- Run by tests/integration/terminal_close_young_job_spec.lua in a Neovim of its own (-u NONE, so that tests/minimal_init.lua
-- does not wait for the exec of the job) with tests/helpers/hold_pty_child.c preloaded. Starts a Claude terminal job,
-- closes it as soon as its child is held, and prints SURVIVED when Neovim is still alive. Environment: CLAUDECODE_TREE is
-- the plugin tree, CASE is `control`, `native`, `snacks` or `owned`, HOLD_PTY_CHILD_READY is the file that the held
-- child creates.
vim.opt.rtp:prepend(vim.env.CLAUDECODE_TREE)
local case = vim.env.CASE

-- Blocks without running events until the child of the job is held: the close then finds a fork of Neovim.
local function wait_until_held()
  local deadline = vim.loop.hrtime() + 5e9
  while not vim.loop.fs_stat(vim.env.HOLD_PTY_CHILD_READY) do
    assert(vim.loop.hrtime() < deadline, "the child of the job was not held within 5 s")
    vim.loop.sleep(1)
  end
end

local config = { split_side = "right", split_width_percentage = 0.3, auto_close = false, auto_insert = false }

-- A stand-in for Snacks.nvim: just enough of Snacks.terminal.open and an instance for the provider. The job is real.
local function stub_snacks()
  local snacks = { terminal = {}, util = { wo = function() end } }
  function snacks.terminal.list()
    return {}
  end
  function snacks.terminal.open(cmd, opts)
    local buf = vim.api.nvim_create_buf(false, true)
    local term = { buf = buf, opts = { wo = {}, w = {}, position = "float" } }
    term.win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = math.max(vim.o.columns - 4, 20),
      height = math.max(vim.o.lines - 6, 5),
    })
    function term:buf_valid()
      return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
    end
    function term:win_valid()
      return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
    end
    function term:on() end
    function term:_on() end
    function term:fixbuf() end
    function term:map() end
    function term:focus() end
    function term:hide()
      if self:win_valid() then
        pcall(vim.api.nvim_win_close, self.win, true)
      end
      self.win = nil
      return self
    end
    function term:show()
      return self
    end
    function term:toggle()
      return self
    end
    function term:close()
      if self:win_valid() then
        pcall(vim.api.nvim_win_close, self.win, true)
      end
      self.win = nil
      if self:buf_valid() then
        pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
      end
    end
    if opts.win and opts.win.on_buf then
      opts.win.on_buf(term)
    end
    vim.api.nvim_buf_call(buf, function()
      vim.fn.termopen(cmd)
    end)
    return term
  end
  package.loaded["snacks"] = snacks
end

if case == "control" then
  local job = vim.fn.termopen({ "sleep", "5" })
  wait_until_held()
  vim.fn.jobstop(job)
elseif case == "owned" then
  local owned = require("claudecode.terminal.owned")
  vim.cmd("enew")
  vim.fn.termopen({ "sleep", "5" })
  vim.b[owned.SNACKS_MARK] = true
  wait_until_held()
  assert(owned.stop_other(owned.SNACKS_MARK, "snacks"), "owned.lua stopped the job")
else
  if case == "snacks" then
    stub_snacks()
  end
  local provider = require("claudecode.terminal." .. case)
  provider.open("sleep 5", { PROBE = "1" }, config, true)
  assert(provider.get_active_bufnr(), "the provider tracks the terminal")
  wait_until_held()
  provider.close()
end
vim.wait(300)
io.stdout:write("SURVIVED\n")
io.stdout:flush()
vim.cmd("qa!")

-- Real-Neovim check of the termopen wrapper in tests/minimal_init.lua: a pty job's child has run exec when termopen
-- returns. Until then the child is a copy of Neovim, and a hangup that reaches it kills Neovim (see minimal_init.lua).
-- scripts/run_integration_tests_individually.sh runs this in Neovim, so busted's mock vim leaves it pending.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("terminal jobs in the integration suite", function()
    pending("needs a real Neovim")
  end)
  return
end

local self_exe = vim.loop.fs_readlink("/proc/self/exe")
if not self_exe then
  describe("terminal jobs in the integration suite", function()
    pending("needs /proc")
  end)
  return
end

describe("terminal jobs in the integration suite", function()
  after_each(function()
    vim.cmd("silent! %bwipeout!")
  end)

  it("have run exec when termopen returns", function()
    for attempt = 1, 40 do
      vim.cmd("enew")
      local job = vim.fn.termopen({ "sleep", "60" })
      local exe = vim.loop.fs_readlink("/proc/" .. vim.fn.jobpid(job) .. "/exe")
      assert.are_not.equal(self_exe, exe, "the child of job " .. attempt .. " still runs Neovim's code")
      vim.fn.jobstop(job)
    end
  end)
end)

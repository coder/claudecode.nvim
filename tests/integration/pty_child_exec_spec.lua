-- Real-Neovim checks of the termopen wrapper that tests/minimal_init.lua installs (tests/helpers/termopen_wait.lua): a
-- pty job's child has run exec when termopen returns. Until then the child is a copy of Neovim, and a hangup that
-- reaches it kills Neovim. The race cannot be timed in a spec: a TermOpen autocmd that takes a few milliseconds lets
-- the child run exec first, with or without the wrapper. So the wait is checked with stand-ins for /proc, a check that
-- the wrapper is installed, and four checks with real jobs.
-- scripts/run_integration_tests_individually.sh runs this in Neovim, so busted's mock vim leaves it pending.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the termopen wrapper of the integration suite", function()
    pending("needs a real Neovim")
  end)
  return
end

local self_exe = vim.loop.fs_readlink("/proc/self/exe")
local self_cmdline_file = io.open("/proc/self/cmdline", "rb")
if not self_exe or not self_cmdline_file then
  describe("the termopen wrapper of the integration suite", function()
    pending("needs /proc")
  end)
  return
end
local self_cmdline = self_cmdline_file:read("*a")
self_cmdline_file:close()

local wrap = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/helpers/termopen_wait.lua")

describe("the termopen wrapper of the integration suite", function()
  local group = "pty_child_exec_spec"

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, group)
    vim.cmd("silent! %bwipeout!")
  end)

  -- `pre_exec_polls` is how many reads of the child's executable still show Neovim's code. `args` overrides `exe` and
  -- `cmdline` of the child after exec.
  local function fake_wrapper(pre_exec_polls, args)
    args = args or {}
    local fake = { clock = 0, sleeps = 0, reads = 0 }
    local termopen = wrap(function()
      return 7
    end, {
      readlink = function(path)
        if path == "/proc/self/exe" then
          return self_exe
        end
        assert.equal("/proc/4242/exe", path)
        assert(fake.reads < 100000, "the wrapper still reads after 100000 polls")
        fake.reads = fake.reads + 1
        return fake.reads <= pre_exec_polls and self_exe or args.exe or "/usr/bin/sleep"
      end,
      read = function(pid, name)
        assert.equal("cmdline", name)
        if pid == "self" then
          return self_cmdline
        end
        assert.equal(4242, pid)
        return fake.reads <= pre_exec_polls and self_cmdline or args.cmdline or "sleep\0" .. "60\0"
      end,
      jobpid = function(job)
        assert.equal(7, job)
        return 4242
      end,
      hrtime = function()
        return fake.clock
      end,
      sleep = function(ms)
        assert(fake.sleeps < 20000, "the wrapper still waits after 20 s")
        fake.sleeps = fake.sleeps + 1
        fake.clock = fake.clock + ms * 1e6
      end,
    })
    return termopen, fake
  end

  it("is installed on vim.fn.termopen", function()
    local source = debug.getinfo(vim.fn.termopen, "S").source
    assert.is_truthy(source:find("helpers/termopen_wait.lua", 1, true), source)
  end)

  it("waits while the child still runs Neovim's code, and returns the job id after exec", function()
    local termopen, fake = fake_wrapper(5)
    assert.equal(7, termopen({ "sleep", "60" }))
    assert.is_true(fake.sleeps >= 5, "waited for the 5 reads of a child that runs Neovim's code")
    assert.is_true(fake.reads >= 6, "read the child's executable after its last read as Neovim's")
  end)

  it("does not wait for a child that has run exec", function()
    local termopen, fake = fake_wrapper(0)
    assert.equal(7, termopen({ "sleep", "60" }))
    assert.equal(0, fake.sleeps)
  end)

  it("does not wait for a child that is Neovim again with its own command line", function()
    local termopen, fake = fake_wrapper(0, { exe = self_exe, cmdline = "nvim\0--headless\0" })
    assert.equal(7, termopen({ vim.v.progpath, "--headless" }))
    assert.equal(0, fake.sleeps)
  end)

  it("raises when the child has not run exec within 10 s", function()
    local termopen, fake = fake_wrapper(math.huge)
    local ok, err = pcall(termopen, { "sleep", "60" })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("did not run exec within 10 s", 1, true), tostring(err))
    assert.is_true(fake.clock >= 10e9, "waited the 10 s")
  end)

  it("does not wait when the job has no pid", function()
    local sleeps = 0
    local termopen = wrap(function()
      return -1
    end, {
      jobpid = function()
        error("E900: Invalid channel id")
      end,
      sleep = function()
        sleeps = sleeps + 1
      end,
    })
    assert.equal(-1, termopen({ "/nonexistent" }))
    assert.equal(0, sleeps)
  end)

  local function start_job(on_exit)
    vim.cmd("enew")
    return vim.fn.termopen({ "sleep", "60" }, on_exit and { on_exit = on_exit } or vim.empty_dict())
  end

  it("returns after exec for a real job", function()
    -- The child copies this environment before exec, which keeps it in Neovim's code for a few milliseconds.
    local env = {}
    for number = 1, 20000 do
      env["PTY_CHILD_EXEC_" .. number] = "x"
    end
    for attempt = 1, 5 do
      vim.cmd("enew")
      local job = vim.fn.termopen({ "sleep", "60" }, { env = env })
      local exe = vim.loop.fs_readlink("/proc/" .. vim.fn.jobpid(job) .. "/exe")
      assert.are_not.equal(self_exe, exe, "the child of job " .. attempt .. " still runs Neovim's code")
      vim.fn.jobstop(job)
    end
  end)

  it("returns the job id when a TermOpen autocmd stops the job", function()
    local exited = false
    vim.api.nvim_create_augroup(group, { clear = true })
    vim.api.nvim_create_autocmd("TermOpen", {
      group = group,
      once = true,
      callback = function()
        vim.fn.jobstop(vim.b.terminal_job_id)
      end,
    })
    local ok, job = pcall(start_job, function()
      exited = true
    end)
    assert.is_true(ok, tostring(job))
    assert.is_true(type(job) == "number" and job > 0)
    assert.is_true(vim.wait(2000, function()
      return exited
    end, 5))
  end)

  it("returns the job id when a TermOpen autocmd wipes the buffer of the job", function()
    vim.api.nvim_create_augroup(group, { clear = true })
    vim.api.nvim_create_autocmd("TermOpen", {
      group = group,
      once = true,
      callback = function()
        vim.cmd("bwipeout!")
      end,
    })
    local ok, job = pcall(start_job)
    assert.is_true(ok, tostring(job))
    assert.is_true(type(job) == "number" and job > 0)
    vim.wait(300)
  end)

  it("returns at once for a job that runs Neovim itself", function()
    local started = vim.loop.hrtime()
    vim.cmd("enew")
    local job = vim.fn.termopen({ vim.v.progpath, "--headless", "-u", "NONE", "-n", "-c", "sleep 100" })
    assert.is_true(vim.loop.hrtime() - started < 5e9, "termopen returned within 5 s")
    assert.equal(self_exe, vim.loop.fs_readlink("/proc/" .. vim.fn.jobpid(job) .. "/exe"))
    vim.fn.jobstop(job)
  end)
end)

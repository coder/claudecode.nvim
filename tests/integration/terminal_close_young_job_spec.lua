-- Real-Neovim checks that closing a Claude terminal right after it started does not end Neovim. Neovim forks the child
-- of a pty job with its own signal handlers and resets them a few system calls later (init_child()). A jobstop in that
-- window ends Neovim with "Caught deadly signal 'SIGHUP'". tests/helpers/hold_pty_child.c holds the child in the window,
-- so each case is a Neovim of its own that starts a Claude terminal job and closes it as soon as its child is held
-- (tests/helpers/close_young_job_probe.lua). It runs with -u NONE: tests/minimal_init.lua makes termopen wait for the
-- exec and would hide the race. The close of the native provider waits for the exec since #544, and the close of the
-- snacks provider and the stop in owned.lua wait the same way.
-- scripts/run_integration_tests_individually.sh runs this in Neovim, so busted's mock vim leaves it pending.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("closing a Claude terminal right after it started", function()
    pending("needs a real Neovim")
  end)
  return
end

local compiler = vim.fn.exepath("cc") ~= "" and vim.fn.exepath("cc") or vim.fn.exepath("gcc")
if vim.loop.os_uname().sysname ~= "Linux" or compiler == "" or vim.fn.executable("timeout") ~= 1 then
  describe("closing a Claude terminal right after it started", function()
    pending("needs Linux, a C compiler and timeout")
  end)
  return
end

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local ld_preload_path = dofile(root .. "/tests/helpers/ld_preload_path.lua")

describe("closing a Claude terminal right after it started", function()
  local dir
  local shim

  before_each(function()
    dir = vim.fn.tempname()
    -- A TMPDIR with a space or a colon cannot hold the shim: see tests/helpers/ld_preload_path.lua.
    if ld_preload_path.can_name_a_shim(dir) then
      vim.fn.mkdir(dir, "p")
    else
      dir = vim.trim(vim.fn.system({ "mktemp", "-d", "/tmp/claudecode.XXXXXX" }))
      assert.equal(0, vim.v.shell_error)
    end
    shim = dir .. "/hold_pty_child.so"
    local output =
      vim.fn.system({ compiler, "-shared", "-fPIC", "-o", shim, root .. "/tests/helpers/hold_pty_child.c", "-ldl" })
    assert.equal(0, vim.v.shell_error, output)
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  -- Runs a case in a Neovim of its own, with the child of its job held, and returns its output and exit code.
  local function run_case(case)
    local output = vim.fn.system({
      "env",
      "LD_PRELOAD=" .. shim,
      "HOLD_PTY_CHILD_READY=" .. dir .. "/held",
      "CLAUDECODE_TREE=" .. root,
      "CASE=" .. case,
      "timeout",
      "-k",
      "3",
      "30",
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-n",
      "-c",
      "luafile " .. root .. "/tests/helpers/close_young_job_probe.lua",
    })
    return output, vim.v.shell_error
  end

  it("ends Neovim with SIGHUP for a plain jobstop, so the cases below can fail", function()
    local output, code = run_case("control")

    assert.is_truthy(output:find("Caught deadly signal 'SIGHUP'", 1, true), output)
    assert.is_falsy(output:find("SURVIVED", 1, true), output)
    assert.are_not.equal(0, code)
  end)

  for _, case in ipairs({ "native", "snacks", "owned" }) do
    it("keeps Neovim alive for " .. case, function()
      local output, code = run_case(case)

      assert.is_truthy(output:find("SURVIVED", 1, true), output)
      assert.equal(0, code, output)
    end)
  end
end)

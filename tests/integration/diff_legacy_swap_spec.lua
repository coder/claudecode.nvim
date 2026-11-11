-- Real-Neovim check that the legacy diff.open_diff opens its proposal when another Neovim left a swap file for the
-- proposal's name ("<path> (New)"). Swap files need a real Neovim, so under busted's mock vim this is pending;
-- scripts/run_integration_tests_individually.sh runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("legacy open_diff and a swap file for its proposal", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("legacy open_diff and a swap file for its proposal", function()
  local diff = require("claudecode.diff")
  local dir, swap_dir, path, saved_directory

  before_each(function()
    dir = vim.fn.tempname()
    swap_dir = dir .. "/swap"
    vim.fn.mkdir(swap_dir, "p")
    path = dir .. "/foo.lua"
    vim.fn.writefile({ "local a = 1" }, path)
    saved_directory = vim.o.directory
    vim.o.directory = swap_dir .. "//"
    diff.setup({ diff_opts = {} })
  end)

  after_each(function()
    vim.cmd("silent! diffoff!")
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.o.directory = saved_directory
    vim.fn.delete(dir, "rf")
  end)

  it("opens the proposal when a killed Neovim left a swap file for '<path> (New)'", function()
    -- Another Neovim changes a buffer named "<path> (New)", so its swap file records that name, and is killed. SIGKILL
    -- leaves the socket folder of that Neovim in $TMPDIR (or $XDG_RUNTIME_DIR), so it gets folders of its own inside
    -- `dir`, which after_each deletes.
    local child_dir = dir .. "/child"
    vim.fn.mkdir(child_dir, "p")
    local job = vim.fn.jobstart({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "--cmd",
      "set directory=" .. vim.fn.fnameescape(swap_dir) .. "//",
      "-c",
      "edit " .. vim.fn.fnameescape(path .. " (New)"),
      "-c",
      "call setline(1, 'unsaved')",
      "-c",
      "preserve",
      "-c",
      "lua (vim.uv or vim.loop).kill(vim.fn.getpid(), 9)",
    }, { stdin = "null", env = { TMPDIR = child_dir, XDG_RUNTIME_DIR = child_dir } })
    assert.is_true(job > 0, "the child Neovim started")
    vim.fn.jobwait({ job }, 30000)
    assert.are.equal(1, #vim.fn.glob(swap_dir .. "/*", false, true), "the killed Neovim left its swap file")

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local ok, result = pcall(diff.open_diff, path, path, "local a = 2\n", "legacy swap")

    assert.is_true(ok, tostring(result))
    assert.is_true(result.success)
    local proposal = vim.api.nvim_get_current_buf()
    assert.are.equal(path .. " (New)", vim.api.nvim_buf_get_name(proposal))
    assert.is_false(vim.bo[proposal].swapfile)
    assert.are.equal("", vim.fn.swapname(proposal))
  end)
end)

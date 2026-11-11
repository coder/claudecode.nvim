-- Real-Neovim check that the legacy diff.open_diff removes its temp file, its proposal buffer and its split window when
-- a step after the temp file was written fails. The cleanup autocmd of a finished diff is registered last, so before
-- this check a failure left the temp file behind. Swap files and autocmd errors need a real Neovim, so under busted's
-- mock vim this is pending; scripts/run_integration_tests_individually.sh runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("legacy open_diff when a step fails after the temp file was written", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("legacy open_diff when a step fails after the temp file was written", function()
  local diff = require("claudecode.diff")
  local dir, swap_dir, path, saved_directory, fterr_group

  -- Every file in a session folder of the plugin's diff temp files.
  local function temp_files()
    local files = vim.fn.glob(vim.fn.stdpath("cache") .. "/claudecode_diffs/*/*", false, true)
    table.sort(files)
    return files
  end

  -- Buffers of the proposal: its temp file ("foo.lua.new") or its final name ("foo.lua (New)").
  local function proposal_buffers()
    local names = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name:find("foo.lua.new", 1, true) or name:find("foo.lua (New)", 1, true) then
        table.insert(names, name)
      end
    end
    return names
  end

  local function window_count()
    return #vim.api.nvim_tabpage_list_wins(0)
  end

  local function diff_windows()
    local count = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[win].diff then
        count = count + 1
      end
    end
    return count
  end

  -- Another Neovim changes `file` and is killed after :preserve, which leaves a swap file whose header names it.
  -- SIGKILL leaves the socket folder of that Neovim in $TMPDIR (or $XDG_RUNTIME_DIR), so it gets folders of its own
  -- inside `dir`, which after_each deletes.
  local function leave_swap_file_of(file)
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
      "edit " .. vim.fn.fnameescape(file),
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
  end

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
    if fterr_group then
      pcall(vim.api.nvim_del_augroup_by_id, fterr_group)
      fterr_group = nil
    end
    vim.cmd("silent! diffoff!")
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.o.directory = saved_directory
    vim.fn.delete(dir, "rf")
  end)

  it("removes its temp file and window when a buffer already has the proposal's name (E95)", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local first = diff.open_diff(path, path, "local a = 2\n", "first")
    assert.is_true(first.success)
    local first_buffer = vim.api.nvim_get_current_buf()
    local files, windows, diffing = temp_files(), window_count(), diff_windows()

    local ok, err = pcall(diff.open_diff, path, path, "local a = 3\n", "second")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.are.same(files, temp_files())
    assert.are.equal(windows, window_count())
    assert.are.equal(diffing, diff_windows())
    assert.is_true(vim.api.nvim_buf_is_valid(first_buffer), "the first diff is still open")
    assert.are.equal(1, vim.fn.filereadable(first.temp_file))
  end)

  it("removes its temp file when a swap file for the original makes the edit fail (E325)", function()
    leave_swap_file_of(path)
    local files, windows = temp_files(), window_count()

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "swap of the original")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E325", 1, true), tostring(err))
    assert.are.same(files, temp_files())
    assert.are.equal(windows, window_count())
    assert.are.equal(0, diff_windows())
  end)

  -- The temp file's name ends in ".new", which filetype detection ignores, so FileType fires for lua while the proposal
  -- is made, and an error in that autocmd reaches the caller (from the edit, or on Neovim 0.8 from setting the
  -- filetype). Where it is only a message, the diff opens. Either way, no temp file stays once the buffers go.
  it("leaves no temp file when a FileType autocmd errors while the proposal's filetype is set", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local files, windows = temp_files(), window_count()
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = fterr_group,
      pattern = "lua",
      callback = function()
        error("boom from FileType")
      end,
    })

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "filetype autocmd")
    if not ok then
      assert.are.equal(windows, window_count())
      assert.are.equal(0, diff_windows())
      assert.are.same({}, proposal_buffers(), "the buffer of the proposal was wiped, although its edit raised")
    end
    vim.cmd("silent! diffoff!")
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")

    assert.are.same(files, temp_files())
  end)

  -- The tab where open_diff starts has only a prompt window, so the diff opens in the editor window of another tab. A
  -- FileType autocmd raises while the temp file is edited, so the buffer of the proposal is never recorded and only the
  -- windows can say where the diff split.
  it(
    "closes the windows it split off in the tab of the editor window it picked, not in the tab it started in",
    function()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      local editor_tab = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      vim.cmd("enew")
      vim.bo.buftype = "prompt"
      local start_win, start_tab = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
      fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
      vim.api.nvim_create_autocmd("FileType", {
        group = fterr_group,
        pattern = "lua",
        callback = function()
          error("boom from FileType")
        end,
      })
      local files, editor_windows = temp_files(), #vim.api.nvim_tabpage_list_wins(editor_tab)

      local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "other tab")

      if not ok then
        assert.are.same(files, temp_files())
        assert.are.equal(editor_windows, #vim.api.nvim_tabpage_list_wins(editor_tab))
        assert.are.equal(start_win, vim.api.nvim_get_current_win(), "the window it started in is current again")
        assert.are.equal(start_tab, vim.api.nvim_get_current_tabpage())
      end
    end
  )

  -- The FileType autocmd runs while the proposal's temp file is edited. It opens a window of its own and then fails.
  it("keeps a window that an autocmd opened while the diff failed", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local files, windows = temp_files(), window_count()
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = fterr_group,
      pattern = "lua",
      callback = function()
        vim.cmd("botright new")
        error("boom from FileType")
      end,
    })

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "autocmd window")

    if not ok then
      assert.are.equal(windows + 1, window_count(), "only the window of the autocmd is left")
      assert.are.same(files, temp_files())
    end
  end)
end)

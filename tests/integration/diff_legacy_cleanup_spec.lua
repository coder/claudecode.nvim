-- Real-Neovim check of what the legacy diff.open_diff does when a step fails after its temp file was written. The
-- cleanup autocmd of a finished diff is registered last, so a failure left the temp file behind. The failed diff now
-- removes the temp file, and the buffer that has the temp file's name when nothing shows or holds it. That is all it
-- does: it closes no window, moves no focus and turns no diff mode off, so the windows that the failed diff had split
-- stay, and a window, a buffer or a diff mode that is not the diff's own must come through untouched. Swap files and
-- autocmd errors need a real Neovim, so under busted's mock vim this is pending;
-- scripts/run_integration_tests_individually.sh runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("legacy open_diff when a step fails after the temp file was written", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("legacy open_diff when a step fails after the temp file was written", function()
  local diff = require("claudecode.diff")
  local dir, swap_dir, path, saved_directory, saved_cache_home, fterr_group

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

  -- Raises in every FileType autocmd for lua whose buffer name matches `name_pattern` (a Lua pattern, nil for all).
  local function raise_in_file_type(name_pattern)
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = fterr_group,
      pattern = "lua",
      callback = function(args)
        if not name_pattern or vim.api.nvim_buf_get_name(args.buf):find(name_pattern) then
          error("boom from FileType")
        end
      end,
    })
  end

  -- Raises in a BufFilePost autocmd for a buffer that gets the proposal's final name, which is after the rename.
  local function raise_after_rename()
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("BufFilePost", {
      group = fterr_group,
      callback = function(args)
        if vim.api.nvim_buf_get_name(args.buf):find("(New)", 1, true) then
          error("boom from BufFilePost")
        end
      end,
    })
  end

  -- A buffer that has the proposal's final name already, so that the rename to it raises E95. Returns its name.
  local function plant_proposal_name()
    local squatter = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(squatter, path .. " (New)")
    return vim.api.nvim_buf_get_name(squatter)
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

  -- The windows that Neovim closed while the failing call ran: a failed diff must not close any.
  local closed
  local function track_closed_windows()
    closed = {}
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = false })
    vim.api.nvim_create_autocmd("WinClosed", {
      group = fterr_group,
      callback = function(args)
        table.insert(closed, args.match)
      end,
    })
  end

  -- The windows of the current tab that are in diff mode.
  local function windows_in_diff_mode()
    local wins = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[win].diff then
        table.insert(wins, win)
      end
    end
    return wins
  end

  local function assert_still_in_diff_mode(wins)
    for _, win in ipairs(wins) do
      assert.is_true(vim.api.nvim_win_is_valid(win), "a window that was in diff mode is open")
      assert.is_true(vim.wo[win].diff, "a window that was in diff mode still is")
    end
  end

  before_each(function()
    dir = vim.fn.tempname()
    swap_dir = dir .. "/swap"
    vim.fn.mkdir(swap_dir, "p")
    path = dir .. "/foo.lua"
    vim.fn.writefile({ "local a = 1" }, path)
    saved_directory = vim.o.directory
    vim.o.directory = swap_dir .. "//"
    -- The legacy diff writes its proposal under stdpath("cache"); keep that out of the real cache folder.
    saved_cache_home = vim.env.XDG_CACHE_HOME
    vim.env.XDG_CACHE_HOME = dir .. "/cache"
    diff.setup({ diff_opts = {} })
  end)

  after_each(function()
    if fterr_group then
      pcall(vim.api.nvim_del_augroup_by_id, fterr_group)
      fterr_group = nil
    end
    vim.cmd("silent! diffoff!")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.o.directory = saved_directory
    vim.env.XDG_CACHE_HOME = saved_cache_home
    vim.fn.delete(dir, "rf")
  end)

  it("removes its temp file when a buffer already has the proposal's name (E95)", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local first = diff.open_diff(path, path, "local a = 2\n", "first")
    assert.is_true(first.success)
    local first_buffer = vim.api.nvim_get_current_buf()
    local files, diffing = temp_files(), windows_in_diff_mode()
    track_closed_windows()

    local ok, err = pcall(diff.open_diff, path, path, "local a = 3\n", "second")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    -- The caller gets the error that Neovim raised, with the position where it was raised and no second one.
    assert.are.equal(1, select(2, tostring(err):gsub("diff%.lua:%d+:", "")), tostring(err))
    assert.are.same(files, temp_files())
    assert.is_true(vim.api.nvim_buf_is_valid(first_buffer), "the first diff is still open")
    assert.are.equal(1, vim.fn.filereadable(first.temp_file))
    assert_still_in_diff_mode(diffing)
    assert.are.same({}, closed, "no window was closed")
  end)

  it("removes its temp file when a swap file for the original makes the edit fail (E325)", function()
    leave_swap_file_of(path)
    local files = temp_files()

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "swap of the original")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E325", 1, true), tostring(err))
    assert.are.same(files, temp_files())
  end)

  -- The original is the current buffer, so `edit` reads it again and fires FileType for lua. An error in that autocmd
  -- stops the diff at its first step.
  it("removes its temp file when a FileType autocmd errors while the original is read again", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local files = temp_files()
    raise_in_file_type()

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "filetype autocmd")

    assert.is_false(ok)
    assert.are.same(files, temp_files())
  end)

  -- The original is loaded but hidden, so `edit` does not read it again and FileType fires for the proposal's temp
  -- file. The edit raises after the split window shows the proposal. A window shows the buffer, so it stays, and no
  -- window is closed.
  it("removes its temp file and closes no window when a FileType autocmd errors for the proposal", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.cmd("enew")
    local files = temp_files()
    raise_in_file_type()
    track_closed_windows()

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "hidden original")

    assert.is_false(ok)
    assert.are.same(files, temp_files())
    assert.are.same({}, closed, "no window was closed")
  end)

  -- Neovim resolves a link in the name of a buffer, so the unlisted buffer that it keeps under the temp file's name
  -- after the rename is not under the name that the plugin built when the cache folder is a link. It is found by its
  -- real path.
  it("wipes the buffer that has the temp file's name when the cache folder is a link", function()
    local real_cache = dir .. "/real_cache"
    vim.fn.mkdir(real_cache, "p")
    assert.is_true((vim.uv or vim.loop).fs_symlink(real_cache, dir .. "/cache_link"))
    vim.env.XDG_CACHE_HOME = dir .. "/cache_link"
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local files = temp_files()
    raise_after_rename()

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "link")

    assert.is_false(ok)
    assert.are.same(files, temp_files())
    for _, name in ipairs(proposal_buffers()) do
      assert.is_nil(name:find("foo.lua.new", 1, true), "no buffer has the temp file's name")
    end
  end)

  -- An autocmd that raises as the buffer is wiped must not stop the cleanup or take the place of the error that failed
  -- the diff. The unlisted buffer that Neovim keeps under the temp file's name after the rename is the one that is wiped.
  it("removes its temp file and raises the first error when an autocmd raises as the buffer is wiped", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local files = temp_files()
    local fired = false
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("BufFilePost", {
      group = fterr_group,
      callback = function(args)
        if vim.api.nvim_buf_get_name(args.buf):find("(New)", 1, true) then
          for _, event in ipairs({ "BufWipeout", "BufDelete", "BufUnload" }) do
            vim.api.nvim_create_autocmd(event, {
              group = fterr_group,
              callback = function()
                fired = true
                error("autocmd for " .. event .. " raised during the cleanup")
              end,
            })
          end
          error("boom from BufFilePost")
        end
      end,
    })

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "raising cleanup")
    vim.api.nvim_clear_autocmds({ group = fterr_group })

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("boom from BufFilePost", 1, true), tostring(err))
    assert.is_true(fired, "the autocmds fired when the buffer was wiped")
    assert.are.same(files, temp_files())
  end)

  -- A BufFilePost autocmd raises when the proposal gets its final name. The buffer has that name now, so only the
  -- temp file is removed. Neovim keeps the old name, the temp file's, in an unlisted buffer, and that one is wiped.
  it("removes its temp file when a step fails after the rename", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local files = temp_files()
    raise_after_rename()

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "after the rename")

    assert.is_false(ok)
    assert.are.same(files, temp_files())
    for _, name in ipairs(proposal_buffers()) do
      assert.is_nil(name:find("foo.lua.new", 1, true), "no buffer has the temp file's name")
    end
  end)

  -- A buffer has the proposal's name already, so the rename raises E95. A window shows the proposal then, and stays.
  it("leaves the buffer that a window shows and the buffer that was there, and removes the temp file", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local squatter_name = plant_proposal_name()
    local files = temp_files()
    track_closed_windows()

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "squatter")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.are.same(files, temp_files())
    assert.are.same({}, closed, "no window was closed")
    local names = proposal_buffers()
    assert.is_true(vim.tbl_contains(names, squatter_name), "the buffer that was there is still there")
  end)

  -- A file tree on the left, and the diff that is open already: no window is free for the next diff, so it takes the
  -- one right of the sidebar, which is the original of the open diff and has diff mode on.
  it("leaves the diff that is open alone when no window is free for the next one", function()
    vim.cmd("enew")
    vim.bo.buftype = "nofile"
    vim.bo.filetype = "neo-tree"
    local sidebar = vim.api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local first = diff.open_diff(path, path, "local a = 2\n", "first")
    assert.is_true(first.success)
    local files, diffing = temp_files(), windows_in_diff_mode()
    assert.are.equal(2, #diffing)
    track_closed_windows()

    local ok, err = pcall(diff.open_diff, path, path, "local a = 3\n", "second")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.are.same(files, temp_files())
    assert.is_true(vim.api.nvim_win_is_valid(sidebar), "the sidebar is open")
    assert_still_in_diff_mode(diffing)
    assert.are.same({}, closed, "no window was closed")
  end)

  -- Two windows already show the file in the user's own diff, so the diff reuses one of them.
  it("leaves a diff of the user's own alone", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.cmd("vsplit")
    vim.cmd("windo diffthis")
    plant_proposal_name()
    local files, diffing = temp_files(), windows_in_diff_mode()
    assert.are.equal(2, #diffing)
    track_closed_windows()

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "user diff")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.are.same(files, temp_files())
    assert_still_in_diff_mode(diffing)
    assert.are.same({}, closed, "no window was closed")
  end)

  -- Edit copies the window options of another window that shows the file, and diff mode is one of them. Whatever the
  -- failed diff leaves there, it does not turn a window's diff mode off or on: that is not the cleanup's to do.
  it("turns no diff mode off in a window of another tab", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local first = diff.open_diff(path, path, "local a = 2\n", "first")
    assert.is_true(first.success)
    local first_tab = vim.api.nvim_get_current_tabpage()
    local diffing = windows_in_diff_mode()
    vim.cmd("tabnew")
    vim.cmd("enew")
    vim.bo.buftype = "prompt"
    local files = temp_files()

    local ok = pcall(diff.open_diff, path, path, "local a = 3\n", "second")

    assert.is_false(ok)
    assert.are.same(files, temp_files())
    for _, win in ipairs(diffing) do
      assert.are.equal(first_tab, vim.api.nvim_win_get_tabpage(win))
      assert.is_true(vim.wo[win].diff, "the first diff is still on")
    end
  end)

  -- The window of the start tab is a prompt, so the diff opens in the editor window of another tab.
  it("closes no window of the tab it started in", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.cmd("tabnew")
    vim.cmd("enew")
    vim.bo.buftype = "prompt"
    local start_win, start_buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    raise_in_file_type("%.new$")
    local files = temp_files()
    track_closed_windows()

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "other tab")

    assert.is_false(ok)
    assert.are.same(files, temp_files())
    assert.is_true(vim.api.nvim_win_is_valid(start_win), "the window it started in is open")
    assert.are.equal(start_buffer, vim.api.nvim_win_get_buf(start_win))
    assert.are.same({}, closed, "no window was closed")
  end)

  -- The FileType autocmd runs while the original is read again. It opens a window of its own and then fails.
  it("keeps a window that an autocmd opened while the diff failed", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local files = temp_files()
    local autocmd_win
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = fterr_group,
      pattern = "lua",
      callback = function()
        vim.cmd("botright new")
        autocmd_win = vim.api.nvim_get_current_win()
        error("boom from FileType")
      end,
    })

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "autocmd window")

    assert.is_false(ok)
    assert.is_true(autocmd_win ~= nil and vim.api.nvim_win_is_valid(autocmd_win), "the window of the autocmd is open")
    assert.are.same(files, temp_files())
  end)

  -- A WinNew handler opens a window of its own, with text in a buffer that is wiped when its window closes.
  it("keeps the unsaved text of a window that a WinNew handler opened while it split", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    plant_proposal_name()
    local files = temp_files()
    local user_buffer
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("WinNew", {
      group = fterr_group,
      once = true,
      callback = function()
        vim.cmd("botright new")
        user_buffer = vim.api.nvim_get_current_buf()
        vim.bo[user_buffer].bufhidden = "wipe"
        vim.api.nvim_buf_set_lines(user_buffer, 0, -1, false, { "user text typed in the new window" })
      end,
    })
    track_closed_windows()

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "winnew text")

    assert.is_false(ok, tostring(err))
    assert.is_true(user_buffer ~= nil and vim.api.nvim_buf_is_valid(user_buffer), "the buffer of the handler is there")
    assert.are.same({ "user text typed in the new window" }, vim.api.nvim_buf_get_lines(user_buffer, 0, -1, false))
    assert.are.same(files, temp_files())
    assert.are.same({}, closed, "no window was closed")
  end)

  -- A WinEnter handler sends the cursor back to the editor window when the diff enters its split, so the proposal
  -- loads into the editor window. That window shows the proposal's buffer, and a wipe would close it.
  it("keeps the editor window when a WinEnter handler sends the cursor back to it", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local editor = vim.api.nvim_get_current_win()
    plant_proposal_name()
    local files = temp_files()
    local fired = false
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("WinEnter", {
      group = fterr_group,
      callback = function()
        if not fired then
          fired = true
          vim.cmd("wincmd p")
        end
      end,
    })
    track_closed_windows()

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "winenter back")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.is_true(fired)
    assert.are.same(files, temp_files())
    assert.is_true(vim.api.nvim_win_is_valid(editor), "the editor window is open")
    assert.are.same({}, closed, "no window was closed")
  end)

  -- A BufEnter handler for the temp file gives the user a new buffer with text in it and wipes the proposal. No buffer
  -- has the temp file's name then, and the buffer of the user must not be taken for it.
  it("leaves a buffer of the user's alone when an autocmd wipes the proposal", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    plant_proposal_name()
    local files = temp_files()
    local user_buffer
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = fterr_group,
      pattern = "*.new",
      once = true,
      callback = function(args)
        vim.cmd("enew")
        user_buffer = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(user_buffer, 0, -1, false, { "user text in a new buffer" })
        vim.api.nvim_buf_delete(args.buf, { force = true })
      end,
    })

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "proposal wiped")

    assert.is_false(ok)
    assert.is_true(user_buffer ~= nil and vim.api.nvim_buf_is_valid(user_buffer), "the buffer of the user is there")
    assert.are.same({ "user text in a new buffer" }, vim.api.nvim_buf_get_lines(user_buffer, 0, -1, false))
    assert.are.same(files, temp_files())
  end)

  -- A BufEnter handler changes the proposal's buffer and sends the window to another buffer, so the proposal is shown in
  -- no window, and it holds text that only it has. The temp file goes, and the buffer stays with its text.
  it("keeps a proposal buffer that has unsaved changes", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    plant_proposal_name()
    local keeper = vim.api.nvim_create_buf(true, false)
    local files = temp_files()
    local proposal
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = fterr_group,
      pattern = "*.new",
      once = true,
      callback = function(args)
        proposal = args.buf
        vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, { "typed into the proposal" })
        vim.cmd("buffer " .. keeper)
      end,
    })

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "modified proposal")

    assert.is_false(ok)
    assert.are.same(files, temp_files())
    assert.is_true(proposal ~= nil and vim.api.nvim_buf_is_valid(proposal), "the proposal's buffer is still there")
    assert.are.same(0, #vim.fn.win_findbuf(proposal), "no window shows it")
    assert.is_true(vim.bo[proposal].modified)
    assert.are.same({ "typed into the proposal" }, vim.api.nvim_buf_get_lines(proposal, 0, -1, false))
  end)
end)

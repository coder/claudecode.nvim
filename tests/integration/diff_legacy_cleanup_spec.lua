-- Real-Neovim check that the legacy diff.open_diff removes its temp file, its proposal buffer and its split windows
-- when a step after the temp file was written fails, and leaves alone what is not its own: a diff mode that was on
-- before the call, and a window or buffer that an autocmd made. The cleanup autocmd of a finished diff is registered
-- last, so before this check a failure left the temp file behind. Swap files and autocmd errors need a real Neovim, so
-- under busted's mock vim this is pending; scripts/run_integration_tests_individually.sh runs it in Neovim.
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
    -- The caller gets the error that Neovim raised, with the position where it was raised and no second one.
    assert.are.equal(1, select(2, tostring(err):gsub("diff%.lua:%d+:", "")), tostring(err))
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

  -- The original is the current buffer, so `edit` reads it again and fires FileType for lua. An error in that autocmd
  -- stops the diff at its first step, before any diff mode, split or proposal.
  it("leaves no temp file when a FileType autocmd errors while the original is read again", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local files, windows = temp_files(), window_count()
    raise_in_file_type()

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "filetype autocmd")

    assert.is_false(ok)
    assert.are.equal(windows, window_count())
    assert.are.equal(0, diff_windows())
    assert.are.same({}, proposal_buffers())
    assert.are.same(files, temp_files())
  end)

  -- The tab where open_diff starts has only a prompt window, so the diff opens in the editor window of another tab. The
  -- diff has split that window and turned diff mode on when a FileType autocmd raises for the proposal, so only the
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
      raise_in_file_type("%.new$")
      local files, editor_windows = temp_files(), #vim.api.nvim_tabpage_list_wins(editor_tab)

      local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "other tab")

      assert.is_false(ok)
      assert.are.same(files, temp_files())
      assert.are.equal(editor_windows, #vim.api.nvim_tabpage_list_wins(editor_tab))
      assert.are.equal(0, diff_windows())
      assert.are.equal(start_win, vim.api.nvim_get_current_win(), "the window it started in is current again")
      assert.are.equal(start_tab, vim.api.nvim_get_current_tabpage())
    end
  )

  -- The FileType autocmd runs while the original is read again. It opens a window of its own and then fails.
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

    assert.is_false(ok)
    assert.are.equal(windows + 1, window_count(), "only the window of the autocmd is left")
    assert.are.same(files, temp_files())
  end)

  -- A WinEnter handler opens a window of its own while the diff splits, so the split is not the current window when
  -- split() returns. The split of the diff, which has diff mode on and the original in it, must not stay behind, and
  -- the window of the handler is not the diff's to close.
  it("closes its own split but not the window that a WinEnter handler opened while it split", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    plant_proposal_name()
    local files, windows = temp_files(), window_count()
    local fired = false
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("WinEnter", {
      group = fterr_group,
      callback = function()
        if not fired then
          fired = true
          vim.cmd("botright new")
        end
      end,
    })

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "winenter")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.are.same(files, temp_files())
    assert.are.equal(windows + 1, window_count(), "only the window of the handler is left")
    assert.are.equal(0, diff_windows(), "no window is left in diff mode")
  end)

  -- Two windows already show the file in the user's own diff, so the diff reuses one of them: edit and diffthis change
  -- nothing there. A failure afterwards must leave that diff alone.
  it("leaves a diff of the user's own alone when it reuses one of its windows", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.cmd("vsplit")
    vim.cmd("windo diffthis")
    plant_proposal_name()
    local files, windows, diffing = temp_files(), window_count(), diff_windows()
    assert.are.equal(2, diffing)

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "user diff")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.are.same(files, temp_files())
    assert.are.equal(windows, window_count())
    assert.are.equal(diffing, diff_windows(), "the user's diff is still on in both windows")
  end)

  -- A file tree on the left, and the diff that is open already: no window is free for the next diff, so it takes the
  -- one right of the sidebar, which is the original of the open diff and has diff mode on.
  it("leaves the diff that is open alone when no window is free for the next one", function()
    vim.cmd("enew")
    vim.bo.buftype = "nofile"
    vim.bo.filetype = "neo-tree"
    vim.cmd("rightbelow vsplit")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local first = diff.open_diff(path, path, "local a = 2\n", "first")
    assert.is_true(first.success)
    local files, windows, diffing = temp_files(), window_count(), diff_windows()
    assert.are.equal(2, diffing)

    local ok, err = pcall(diff.open_diff, path, path, "local a = 3\n", "second")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.are.same(files, temp_files())
    assert.are.equal(windows, window_count())
    assert.are.equal(diffing, diff_windows(), "the open diff is still on in both windows")
  end)

  -- Edit copies the window options of another window that shows the file, and diff mode is one of them. The window
  -- was not in diff mode before the call, so a failed diff turns it off again.
  it("turns diff mode off again in a window where the edit turned it on", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local first = diff.open_diff(path, path, "local a = 2\n", "first")
    assert.is_true(first.success)
    vim.cmd("tabnew")
    vim.cmd("enew")
    vim.bo.buftype = "prompt"
    local start_win = vim.api.nvim_get_current_win()
    assert.is_false(vim.wo[start_win].diff)

    local ok, err = pcall(diff.open_diff, path, path, "local a = 3\n", "second")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.are.equal(start_win, vim.api.nvim_get_current_win())
    assert.is_false(vim.wo[start_win].diff, "the window is not in diff mode")
  end)

  -- The original is loaded but hidden, so `edit` does not read it again and FileType fires for the proposal's temp
  -- file. The edit raises after the diff has split a window and turned diff mode on, and before the proposal's buffer
  -- is recorded: the buffer is under the temp file's name.
  it("wipes the proposal's buffer and undoes the diff when a FileType autocmd errors for the proposal", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local original = vim.api.nvim_get_current_buf()
    vim.cmd("enew")
    assert.is_true(vim.api.nvim_buf_is_loaded(original), "the original stays loaded")
    local start_win = vim.api.nvim_get_current_win()
    local files, windows = temp_files(), window_count()
    raise_in_file_type()

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "hidden original")

    assert.is_false(ok)
    assert.are.same(files, temp_files())
    assert.are.equal(windows, window_count(), "its split is closed")
    assert.are.equal(0, diff_windows(), "diff mode is off")
    assert.are.same({}, proposal_buffers(), "the buffer of the proposal is wiped")
    assert.are.equal(start_win, vim.api.nvim_get_current_win())
  end)

  -- A BufFilePost autocmd raises when the proposal gets its final name: the failure comes after the rename, after both
  -- splits and after the diff mode of the original. Neovim keeps the old name, the temp file's, in an unlisted buffer.
  it("wipes the proposal's buffer and undoes the diff when a step fails after the rename", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local files, windows = temp_files(), window_count()
    raise_after_rename()

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "after the rename")

    assert.is_false(ok)
    assert.are.same(files, temp_files())
    assert.are.equal(windows, window_count(), "both splits are closed")
    assert.are.equal(0, diff_windows(), "diff mode is off")
    assert.are.same({}, proposal_buffers(), "the buffer of the proposal is wiped")
  end)

  -- The original is the current buffer and a buffer has the proposal's name already, so the rename raises E95 after
  -- both splits, the diff mode of the original and the proposal's buffer.
  it("undoes the whole diff when a buffer already has the proposal's name and the original is current", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local squatter_name = plant_proposal_name()
    local files, windows = temp_files(), window_count()

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "squatter")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.are.same(files, temp_files())
    assert.are.equal(windows, window_count())
    assert.are.equal(0, diff_windows())
    assert.are.same({ squatter_name }, proposal_buffers(), "only the buffer that was there is left")
  end)

  -- Autocmds that raise while the diff is undone must neither stop a later step nor take the place of the error that
  -- made the diff fail. The diff opens in the editor window of another tab, so the rollback closes windows there and
  -- goes back to the tab it started in. The autocmds are armed when the rename starts, so they raise in the rollback
  -- and not before the failure.
  it("finishes the rollback and raises the first error when autocmds raise during it", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local editor_tab = vim.api.nvim_get_current_tabpage()
    plant_proposal_name()
    vim.cmd("tabnew")
    vim.cmd("enew")
    vim.bo.buftype = "prompt"
    local start_win, start_tab = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
    local files, editor_windows = temp_files(), #vim.api.nvim_tabpage_list_wins(editor_tab)
    local fired = {}
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("BufFilePre", {
      group = fterr_group,
      pattern = "*.new",
      once = true,
      callback = function()
        local events = { "WinEnter", "WinLeave", "WinClosed", "BufWipeout", "BufDelete", "BufEnter", "BufLeave" }
        vim.list_extend(events, { "TabEnter", "TabLeave", "BufWinLeave", "BufUnload" })
        for _, event in ipairs(events) do
          vim.api.nvim_create_autocmd(event, {
            group = fterr_group,
            callback = function()
              fired[event] = true
              error("autocmd for " .. event .. " raised in the rollback")
            end,
          })
        end
      end,
    })

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "raising rollback")
    vim.api.nvim_clear_autocmds({ group = fterr_group })

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.is_true(fired.WinClosed and fired.BufWipeout and fired.WinEnter, "the autocmds fired in the rollback")
    assert.are.same(files, temp_files())
    assert.are.equal(editor_windows, #vim.api.nvim_tabpage_list_wins(editor_tab))
    assert.are.equal(0, diff_windows())
    assert.are.equal(start_win, vim.api.nvim_get_current_win(), "the window it started in is current again")
    assert.are.equal(start_tab, vim.api.nvim_get_current_tabpage())
  end)

  -- A WinEnter handler that raises does so after the split exists.
  it("closes its split when a WinEnter handler raises while it splits", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local files, windows = temp_files(), window_count()
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("WinEnter", {
      group = fterr_group,
      once = true,
      callback = function()
        error("boom from WinEnter")
      end,
    })

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "winenter raises")

    assert.is_false(ok)
    assert.are.same(files, temp_files())
    assert.are.equal(windows, window_count(), "the split is closed")
    assert.are.equal(0, diff_windows())
  end)

  -- A WinEnter handler sends the cursor back to the editor window when the diff enters its split. The proposal must
  -- load in the split all the same, and a rollback must leave the editor window and its buffer where they are.
  it("keeps the editor window when a WinEnter handler sends the cursor back to it", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local editor, editor_buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    plant_proposal_name()
    local files, windows = temp_files(), window_count()
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

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "winenter back")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.is_true(fired)
    assert.are.same(files, temp_files())
    assert.is_true(vim.api.nvim_win_is_valid(editor), "the editor window is open")
    assert.are.equal(editor_buffer, vim.api.nvim_win_get_buf(editor))
    assert.are.equal(windows, window_count())
    assert.are.equal(0, diff_windows())
  end)

  -- A WinNew handler opens a window of its own, with text in a buffer that is wiped when its window closes. The
  -- window is the user's: a rollback must not close it.
  it("keeps the unsaved text of a window that a WinNew handler opened while it split", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    plant_proposal_name()
    local files, windows = temp_files(), window_count()
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

    local ok, err = pcall(diff.open_diff, path, path, "local a = 2\n", "winnew text")

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E95", 1, true), tostring(err))
    assert.is_true(user_buffer ~= nil and vim.api.nvim_buf_is_valid(user_buffer), "the buffer of the handler is there")
    assert.are.same({ "user text typed in the new window" }, vim.api.nvim_buf_get_lines(user_buffer, 0, -1, false))
    assert.are.same(files, temp_files())
    assert.are.equal(windows + 1, window_count(), "only the window of the handler is left")
    assert.are.equal(0, diff_windows())
  end)

  -- The handler turns the new split into a window of its own: a buffer of the user's with unsaved text that is wiped
  -- when its window closes. The diff cannot load the original there (E37), and the window must stay, because a close
  -- with force would wipe the text.
  it("does not force a split closed that an autocmd gave a modified buffer of its own", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local files, windows = temp_files(), window_count()
    local user_buffer
    fterr_group = vim.api.nvim_create_augroup("ClaudeCodeDiffLegacyCleanupSpec", { clear = true })
    vim.api.nvim_create_autocmd("WinNew", {
      group = fterr_group,
      once = true,
      callback = function()
        vim.cmd("enew")
        user_buffer = vim.api.nvim_get_current_buf()
        vim.bo[user_buffer].bufhidden = "wipe"
        vim.api.nvim_buf_set_lines(user_buffer, 0, -1, false, { "user text in the split" })
      end,
    })

    local ok = pcall(diff.open_diff, path, path, "local a = 2\n", "modified split")

    assert.is_false(ok)
    assert.is_true(user_buffer ~= nil and vim.api.nvim_buf_is_valid(user_buffer), "the buffer of the handler is there")
    assert.are.same({ "user text in the split" }, vim.api.nvim_buf_get_lines(user_buffer, 0, -1, false))
    assert.are.same(files, temp_files())
    assert.are.equal(0, diff_windows())
    assert.is_true(window_count() >= windows, "no window of the user's was closed")
  end)
end)

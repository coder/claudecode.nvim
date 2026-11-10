-- Real-Neovim check that openFile ends with the whole file in the buffer when a user's autocommand fails while
-- openFile loads a changed file again. Run from Lua, such an error stops the load halfway and leaves the old text
-- with empty lines added, so openFile reads the file again before it fails. The recovery must not depend on the
-- event: an error in a user's BufReadPre autocommand also stops every BufReadPre autocommand after it. The second
-- read must leave alone a buffer that the failing autocommand changed, and a buffer that it wiped.
-- It needs real autocommands, so under busted's mock vim it is pending; scripts/run_integration_tests_individually.sh
-- runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openFile when a user's autocommand fails while it loads a changed file", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openFile when a user's autocommand fails while it loads a changed file", function()
  local open_file = require("claudecode.tools.open_file")
  local uv = vim.uv or vim.loop
  local old_text = { "old1", "old2", "old3" }
  local new_text = { "new1", "new2", "new3", "new4", "new5" }
  local group
  local bumps = 0
  local autoread, autowriteall

  -- Rewrites `path` with `lines` and sets its mtime ahead, so every change gets a time of its own.
  local function change_on_disk(path, lines)
    vim.fn.writefile(lines, path)
    bumps = bumps + 3
    local time = os.time() + 5 + bumps
    uv.fs_utime(path, time, time)
  end

  -- Adds a user autocommand for `event` that runs `before_error(args)`, if given, and then fails.
  local function fail_in(event, before_error)
    vim.api.nvim_create_autocmd(event, {
      group = group,
      pattern = "*",
      callback = function(args)
        if before_error then
          before_error(args)
        end
        error("user " .. event .. " boom")
      end,
    })
  end

  -- Shows `old_text` of a new file in the current window and then changes the file on disk to `new_text`.
  local function show_old_text_then_change_file()
    local path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile(old_text, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    change_on_disk(path, new_text)
    return path, buf
  end

  before_each(function()
    autoread, autowriteall = vim.o.autoread, vim.o.autowriteall
    vim.o.autoread = true
    group = vim.api.nvim_create_augroup("OpenFileReloadErrorSpec", { clear = true })
    vim.cmd("silent! %bwipeout!")
  end)

  after_each(function()
    vim.api.nvim_del_augroup_by_id(group)
    vim.o.autoread, vim.o.autowriteall = autoread, autowriteall
    vim.cmd("silent! %bwipeout!")
  end)

  for _, event in ipairs({ "BufReadPre", "BufReadPost", "FileChangedShellPost" }) do
    it("loads the whole file, then fails, when a " .. event .. " autocommand fails", function()
      local path, buf = show_old_text_then_change_file()
      fail_in(event)

      local success, err = pcall(open_file.handler, { filePath = path })

      assert.is_false(success)
      assert.is_truthy(tostring(err):find("user " .. event .. " boom", 1, true))
      assert.are.same(new_text, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.is_false(vim.bo[buf].modified)
      assert.is_false(vim.bo[buf].readonly)
    end)
  end

  for _, event in ipairs({ "BufReadPre", "BufReadPost" }) do
    it(
      "loads the whole file, then fails, when a " .. event .. " autocommand fails for a buffer made before its file",
      function()
        local path = vim.fn.tempname() .. ".txt"
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        local buf = vim.api.nvim_get_current_buf()
        change_on_disk(path, new_text)
        fail_in(event)

        local success, err = pcall(open_file.handler, { filePath = path })

        assert.is_false(success)
        assert.is_truthy(tostring(err):find("user " .. event .. " boom", 1, true))
        assert.are.same(new_text, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      end
    )
  end

  it("loads the whole file, then fails, when a FileChangedShell autocommand fails and 'autoread' is off", function()
    vim.o.autoread = false
    local path, buf = show_old_text_then_change_file()
    fail_in("FileChangedShell")

    local success, err = pcall(open_file.handler, { filePath = path })

    assert.is_false(success)
    assert.is_truthy(tostring(err):find("user FileChangedShell boom", 1, true))
    assert.are.same(new_text, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("keeps the unsaved text when a FileChangedShell autocommand fails", function()
    local path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile(old_text, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "EDITED" })
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.tempname() .. ".txt")) -- hides the buffer with unsaved changes
    change_on_disk(path, new_text)
    fail_in("FileChangedShell")

    local success, err = pcall(open_file.handler, { filePath = path })

    assert.is_false(success)
    assert.is_truthy(tostring(err):find("user FileChangedShell boom", 1, true))
    assert.are.same({ "EDITED", "old2", "old3" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("keeps what a user's autocommand wrote into the buffer before it failed", function()
    local path, buf = show_old_text_then_change_file()
    fail_in("FileChangedShellPost", function(args)
      vim.api.nvim_buf_set_lines(args.buf, 0, 1, false, { "EDITED" })
    end)

    local success, err = pcall(open_file.handler, { filePath = path })

    assert.is_false(success)
    assert.is_truthy(tostring(err):find("user FileChangedShellPost boom", 1, true))
    assert.are.same({ "EDITED", "new2", "new3", "new4", "new5" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(vim.bo[buf].modified)
  end)

  -- With 'autowriteall' a second read of a buffer with unsaved changes would write them over the new file first.
  it("does not write what a user's autocommand wrote into the buffer over the file with 'autowriteall'", function()
    vim.o.autowriteall = true
    local path, buf = show_old_text_then_change_file()
    fail_in("FileChangedShellPost", function(args)
      vim.api.nvim_buf_set_lines(args.buf, 0, 1, false, { "EDITED" })
    end)

    local success = pcall(open_file.handler, { filePath = path })

    assert.is_false(success)
    assert.are.same(new_text, vim.fn.readfile(path))
    assert.is_true(vim.bo[buf].modified)
  end)

  it("fails with the user's error when the autocommand wipes the buffer before it fails", function()
    local path, buf = show_old_text_then_change_file()
    fail_in("FileChangedShellPost", function(args)
      vim.api.nvim_buf_delete(args.buf, { force = true })
    end)

    local success, err = pcall(open_file.handler, { filePath = path })

    assert.is_false(success)
    assert.is_truthy(tostring(err):find("user FileChangedShellPost boom", 1, true))
    assert.is_nil(tostring(err):find("Invalid buffer id", 1, true))
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)
end)

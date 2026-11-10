-- Real-Neovim check that openFile's acwrite step keeps Neovim's guard for a buffer opened before its file existed:
-- Neovim refuses `:w` of such a buffer once the file exists (E13), and 'buftype' acwrite skips that check, so the
-- step also sets 'readonly'. Issue #433.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openFile on a buffer opened before its file existed", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openFile on a buffer opened before its file existed", function()
  local open_file = require("claudecode.tools.open_file")
  local dir, target, other, group, hidden

  local function disk(path)
    return table.concat(vim.fn.readfile(path), "|")
  end

  local function buffer_opened_before_claude_wrote(unsaved)
    vim.cmd("edit " .. vim.fn.fnameescape(target))
    local buf = vim.api.nvim_get_current_buf()
    if unsaved then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { unsaved })
    end
    vim.cmd("edit " .. vim.fn.fnameescape(other))
    vim.fn.writefile({ "CLAUDE" }, target)
    return buf
  end

  local function autocmds(commands)
    for _, command in ipairs(commands) do
      vim.cmd("autocmd OpenFileNewFileWriteSpec " .. command)
    end
  end

  local write_handler = "BufWriteCmd * call writefile(getline(1, '$'), expand('<afile>')) | setlocal nomodified"

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    target, other = dir .. "/target.txt", dir .. "/other.txt"
    vim.fn.writefile({ "other" }, other)
    group = vim.api.nvim_create_augroup("OpenFileNewFileWriteSpec", { clear = true })
    hidden = vim.o.hidden
    vim.o.hidden = true
  end)

  after_each(function()
    vim.api.nvim_del_augroup_by_id(group)
    vim.o.hidden = hidden
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
  end)

  it("keeps Claude's file when a nested BufEnter autocmd writes unsaved text through a BufWriteCmd handler", function()
    local buf = buffer_opened_before_claude_wrote("USER UNSAVED")
    autocmds({ "BufEnter * ++nested update", write_handler })

    local ok, err = pcall(open_file.handler, { filePath = target })

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E45", 1, true))
    assert.are.same("CLAUDE", disk(target))
    assert.are.same({ "USER UNSAVED" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(vim.bo[buf].modified)
    assert.is_false(vim.bo[buf].readonly)
    assert.are.same("", vim.bo[buf].buftype)
  end)

  it("keeps Claude's file when a nested BufLeave autocmd runs :wall and still writes the other buffer", function()
    local buf = buffer_opened_before_claude_wrote("USER UNSAVED")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "other unsaved" })
    autocmds({ "BufLeave * ++nested silent! wall", write_handler })

    open_file.handler({ filePath = target })

    assert.are.same("CLAUDE", disk(target))
    assert.are.same("other unsaved", disk(other))
    assert.are.same({ "USER UNSAVED" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(vim.bo[buf].modified)
    assert.is_false(vim.bo[buf].readonly)
  end)

  it("keeps Claude's file when a nested autocmd runs :write on a buffer without unsaved changes", function()
    buffer_opened_before_claude_wrote(nil)
    autocmds({ "BufEnter * ++nested write", write_handler })

    local ok, err = pcall(open_file.handler, { filePath = target })

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("E45", 1, true))
    assert.are.same("CLAUDE", disk(target))
  end)

  it("turns 'readonly' off after the step and keeps unsaved text", function()
    local buf = buffer_opened_before_claude_wrote("USER UNSAVED")

    open_file.handler({ filePath = target })

    assert.are.same(buf, vim.api.nvim_get_current_buf())
    assert.is_false(vim.bo[buf].readonly)
    assert.is_true(vim.bo[buf].modified)
    assert.are.same({ "USER UNSAVED" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("keeps 'readonly' on for a buffer with unsaved changes that the user set readonly", function()
    vim.cmd("edit " .. vim.fn.fnameescape(target))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "USER UNSAVED" })
    vim.bo[buf].readonly = true
    vim.cmd("edit " .. vim.fn.fnameescape(other))
    vim.fn.writefile({ "CLAUDE" }, target)

    open_file.handler({ filePath = target })

    assert.is_true(vim.bo[buf].readonly)
  end)

  it("lets a BufLeave autosave write the buffer it leaves", function()
    buffer_opened_before_claude_wrote("USER UNSAVED")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "other unsaved" })
    autocmds({ "BufLeave * update" })

    open_file.handler({ filePath = target })

    assert.are.same("other unsaved", disk(other))
    assert.are.same("CLAUDE", disk(target))
  end)
end)

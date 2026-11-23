-- Real-Neovim check that openFile and the diff open a file whose name holds a line break as that one file, and run
-- nothing in the name. fnameescape() puts a backslash before a line break but keeps the line break, and vim.cmd() with a
-- string runs each of its lines as an Ex command, so `vim.cmd("edit " .. vim.fn.fnameescape(path))` ran the text after
-- the line break. Busted's mock vim runs no Ex commands, so under busted this is pending;
-- scripts/run_integration_tests_individually.sh runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("file names with a line break", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("file names with a line break", function()
  local diff = require("claudecode.diff")
  -- After the line break comes an Ex command that sets g:claudecode_injected. fnameescape() changes none of its
  -- characters, and the `--` turns the `.new` that the legacy diff adds to its temp file into a Lua comment.
  local name = "x\nlua(vim.g).claudecode_injected=1--"
  local dir, saved_cache_home

  ---@return integer? buf The buffer named `buf_name`
  local function buffer_named(buf_name)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf) == buf_name then
        return buf
      end
    end
  end

  before_each(function()
    vim.g.claudecode_injected = nil
    -- Neovim resolves links in the folder of a buffer name (macOS: /var is /private/var), so compare real paths.
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = (vim.uv or vim.loop).fs_realpath(dir)
    -- The legacy diff writes its proposal under stdpath("cache"); keep that out of the real cache folder.
    saved_cache_home = vim.env.XDG_CACHE_HOME
    vim.env.XDG_CACHE_HOME = dir .. "/cache"
    diff.setup({ terminal = { provider = "none" }, diff_opts = {} })
    _G.claude_deferred_responses = {}
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! diffoff!")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.env.XDG_CACHE_HOME = saved_cache_home
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
    vim.g.claudecode_injected = nil
  end)

  it("openFile runs nothing in the name", function()
    local path = dir .. "/" .. name
    vim.fn.writefile({ "old text" }, path)

    pcall(require("claudecode.tools.open_file").handler, { filePath = path })

    assert.is_nil(vim.g.claudecode_injected, "the text after the line break ran as an Ex command")
  end)

  it("openDiff opens the original that has the name, and runs nothing in it", function()
    local path = dir .. "/" .. name
    vim.fn.writefile({ "old text" }, path)

    local co = coroutine.create(function()
      return diff.open_diff_blocking(path, path, "new text\n", "line break name", nil)
    end)
    local ok, err = coroutine.resume(co)
    _G.claude_deferred_responses[tostring(co)] = function() end

    assert.is_nil(vim.g.claudecode_injected, "the text after the line break ran as an Ex command")
    assert.is_true(ok, vim.inspect(err))
    assert.equal("suspended", coroutine.status(co), "openDiff waits for the user")
    local original = buffer_named(path)
    assert.is_not_nil(original, "a buffer has the file's name")
    assert.same({ "old text" }, vim.api.nvim_buf_get_lines(original, 0, -1, false))
    local win = vim.fn.win_findbuf(original)[1]
    assert.is_not_nil(win, "a window shows the original")
    assert.is_true(vim.wo[win].diff, "the original is in diff mode")
  end)

  it("the legacy open_diff opens the original that has the name, and runs nothing in it", function()
    local path = dir .. "/" .. name
    vim.fn.writefile({ "old text" }, path)

    local ok, result = pcall(diff.open_diff, path, dir .. "/new.txt", "new text\n", "legacy line break old")

    assert.is_nil(vim.g.claudecode_injected, "the text after the line break ran as an Ex command")
    assert.is_true(ok, vim.inspect(result))
    assert.is_true(result.success)
    local original = buffer_named(path)
    assert.is_not_nil(original, "a buffer has the file's name")
    assert.same({ "old text" }, vim.api.nvim_buf_get_lines(original, 0, -1, false))
  end)

  it("the legacy open_diff opens its temp file named after the new file, and runs nothing in the name", function()
    local old = dir .. "/old.txt"
    vim.fn.writefile({ "old text" }, old)
    local new_path = dir .. "/" .. name

    local ok, result = pcall(diff.open_diff, old, new_path, "new text\n", "legacy line break new")

    assert.is_nil(vim.g.claudecode_injected, "the text after the line break ran as an Ex command")
    assert.is_true(ok, vim.inspect(result))
    assert.is_true(result.success)
    local proposal = buffer_named(new_path .. " (New)")
    assert.is_not_nil(proposal, "the proposal has the new file's name")
    assert.same({ "new text" }, vim.api.nvim_buf_get_lines(proposal, 0, -1, false))
  end)
end)

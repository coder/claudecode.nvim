if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff with a leftover diff buffer under its name", function()
    pending("needs a real Neovim")
  end)
  return
end

-- No active diff owns a proposal buffer that a reload (:Lazy reload) left loaded, or that a failed setup could not
-- delete in the command-line window. A split-layout openDiff for that tab name must open a diff, and the leftover
-- buffer keeps its windows and text under another name.
describe("openDiff with a leftover diff buffer under its name", function()
  local dir
  local path
  local tab_name = "✻ [Claude Code] reload.txt ⧉"

  local function load_plugin(layout)
    for name in pairs(package.loaded) do
      if name == "claudecode" or name:match("^claudecode%.") then
        package.loaded[name] = nil
      end
    end
    require("claudecode").setup({
      auto_start = false,
      log_level = "error",
      terminal = { provider = "none" },
      diff_opts = { layout = layout or "vertical" },
    })
    local tools = require("claudecode.tools.init")
    tools.register_all()
    return require("claudecode.diff"), tools
  end

  local function open_diff(tools, file_contents, name)
    local call = tools.handle_invoke({ id = "reload_proposal_name" }, {
      name = "openDiff",
      arguments = {
        old_file_path = path,
        new_file_path = path,
        new_file_contents = file_contents,
        tab_name = name or tab_name,
      },
    })
    if call._deferred then
      _G.claude_deferred_responses[tostring(call.coroutine)] = function() end
    end
    return call
  end

  local function buffers_named(suffix)
    local wanted = vim.fn.fnamemodify(tab_name .. " " .. suffix, ":p")
    local found = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf) == wanted then
        found[#found + 1] = buf
      end
    end
    return found
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    path = dir .. "/reload.txt"
    vim.fn.writefile({ "alpha" }, path)
    _G.claude_deferred_responses = {}
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end)

  after_each(function()
    pcall(function()
      require("claudecode.diff")._cleanup_all_active_diffs("test cleanup")
    end)
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  local reloads = {
    {
      name = "the diff module",
      reload = function()
        package.loaded["claudecode.diff"] = nil
        local diff = require("claudecode.diff")
        diff.setup({ terminal = { provider = "none" }, diff_opts = {} })
        return diff, require("claudecode.tools.init")
      end,
    },
    { name = "every claudecode module", reload = load_plugin },
  }

  local function in_command_line_window(fn)
    local failure
    vim.api.nvim_create_autocmd("CmdwinEnter", {
      once = true,
      callback = function()
        local ok, err = pcall(fn)
        failure = not ok and err or nil
      end,
    })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q:", true, false, true), "x", false)
    assert(not failure, failure)
  end

  local function close_old_diff_windows()
    vim.cmd("diffoff!")
    vim.cmd("silent! only!")
  end

  for _, case in ipairs(reloads) do
    for _, windows in ipairs({ "open", "closed" }) do
      it(
        "opens a diff for a tab name whose proposal buffer survived a reload of "
          .. case.name
          .. ", windows "
          .. windows,
        function()
          local _, tools = load_plugin()
          assert.is_true(open_diff(tools, "alpha one\n")._deferred)
          local leftover = buffers_named("(proposed)")
          assert.equal(1, #leftover, "the old diff's proposal buffer is loaded")
          vim.api.nvim_buf_set_lines(leftover[1], 0, -1, false, { "accepted text" })
          if windows == "closed" then
            close_old_diff_windows()
          end

          local diff
          diff, tools = case.reload()
          assert.equal(0, vim.tbl_count(diff._get_active_diffs()), "the reloaded module knows no diff")
          local call = open_diff(tools, "alpha two\n")

          assert.is_true(call._deferred, vim.inspect(call.error))
          local state = diff._get_active_diffs()[tab_name]
          assert.is_not_nil(state, "the reloaded module owns the new diff")
          assert.same({ state.new_buffer }, buffers_named("(proposed)"), "the new proposal buffer carries the name")
          assert.same({ "alpha two" }, vim.api.nvim_buf_get_lines(state.new_buffer, 0, -1, false))
          assert.is_true(vim.api.nvim_buf_is_valid(leftover[1]), "the orphaned proposal buffer stays")
          assert.is_not.equal(state.new_buffer, leftover[1])
          assert.same({ "accepted text" }, vim.api.nvim_buf_get_lines(leftover[1], 0, -1, false), "it keeps its text")
        end
      )
    end
  end

  for _, windows in ipairs({ "open", "closed" }) do
    it("opens a new-file diff for a tab name whose proposal buffers survived a reload, windows " .. windows, function()
      path = dir .. "/missing.txt"
      local _, tools = load_plugin()
      assert.is_true(open_diff(tools, "first\n")._deferred)
      local leftover = buffers_named("(NEW FILE - proposed)")
      assert.equal(1, #leftover)
      if windows == "closed" then
        close_old_diff_windows()
      end

      local diff
      diff, tools = load_plugin()
      local call = open_diff(tools, "second\n")

      assert.is_true(call._deferred, vim.inspect(call.error))
      local state = diff._get_active_diffs()[tab_name]
      assert.same({ state.new_buffer }, buffers_named("(NEW FILE - proposed)"))
      assert.is_true(vim.api.nvim_buf_is_valid(leftover[1]), "the orphaned proposal buffer stays")
      assert.is_not.equal(state.new_buffer, leftover[1])
    end)
  end

  it("opens a diff for a tab name whose first setup failed in the command-line window", function()
    local diff, tools = load_plugin()
    local first
    in_command_line_window(function()
      first = open_diff(tools, "alpha one\n")
    end)
    assert.is_truthy(vim.inspect(first.error):find("E11", 1, true), vim.inspect(first))
    assert.equal(0, vim.tbl_count(diff._get_active_diffs()))

    local call = open_diff(tools, "alpha two\n")

    assert.is_true(call._deferred, vim.inspect(call.error))
    local state = diff._get_active_diffs()[tab_name]
    assert.same({ state.new_buffer }, buffers_named("(proposed)"))
    assert.same({ "alpha two" }, vim.api.nvim_buf_get_lines(state.new_buffer, 0, -1, false))
  end)

  local layout_pairs = {
    { old = "vertical", new = "vertical" },
    { old = "vertical", new = "unified" },
    { old = "unified", new = "vertical" },
    { old = "unified", new = "unified" },
  }

  local function suffix_of(layout)
    return layout == "unified" and "(unified diff)" or "(proposed)"
  end

  for _, pair in ipairs(layout_pairs) do
    it(
      "names the new buffer and does not let the old window resolve it: " .. pair.old .. " then " .. pair.new,
      function()
        local _, tools = load_plugin(pair.old)
        assert.is_true(open_diff(tools, "alpha one\n")._deferred)
        local leftover = buffers_named(suffix_of(pair.old))[1]
        local diff
        diff, tools = load_plugin(pair.new)
        assert.is_true(open_diff(tools, "alpha two\n")._deferred)
        local state = diff._get_active_diffs()[tab_name]
        assert.same({ state.new_buffer }, buffers_named(suffix_of(pair.new)), "the new buffer carries the name")

        local notify = vim.notify
        local messages = {}
        vim.notify = function(message)
          messages[#messages + 1] = message
        end
        vim.api.nvim_set_current_win(vim.fn.win_findbuf(leftover)[1])
        local ok, err = pcall(function()
          diff.accept_current_diff()
          diff.deny_current_diff()
        end)
        vim.notify = notify

        assert.is_true(ok, err)
        assert.same({ "No active diff found in current buffer", "No active diff found in current buffer" }, messages)
        assert.equal("pending", state.status, "the new diff still waits for its own proposal window")
      end
    )
  end

  it("opens a new-file diff in a folder that a symlink reaches, after a reload with the old windows closed", function()
    vim.fn.mkdir(dir .. "/real", "p")
    assert(vim.loop.fs_symlink(dir .. "/real", dir .. "/link"))
    path = dir .. "/link/missing.txt"
    local _, tools = load_plugin()
    assert.is_true(open_diff(tools, "first\n")._deferred)
    close_old_diff_windows()

    local diff
    diff, tools = load_plugin()
    local call = open_diff(tools, "second\n")

    assert.is_true(call._deferred, vim.inspect(call.error))
    assert.is_not_nil(diff._get_active_diffs()[tab_name])
  end)

  it("leaves no extra window when the original buffer of a new file cannot take its name", function()
    path = dir .. "/missing.txt"
    local _, tools = load_plugin()
    local foreign = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(foreign, path .. " (NEW FILE)")
    local windows = #vim.api.nvim_tabpage_list_wins(0)
    local tabs = #vim.api.nvim_list_tabpages()

    local call = open_diff(tools, "alpha\n")

    assert.is_truthy(vim.inspect(call.error):find("E95", 1, true), vim.inspect(call.error))
    assert.equal(tabs, #vim.api.nvim_list_tabpages())
    assert.equal(windows, #vim.api.nvim_tabpage_list_wins(0), "the failed setup closes the windows it made")
  end)

  it("does not take the name from the proposal buffer of an active diff", function()
    local diff, tools = load_plugin()
    assert.is_true(open_diff(tools, "alpha one\n")._deferred)

    local ok, err = pcall(diff._setup_blocking_diff, {
      old_file_path = path,
      new_file_path = path,
      new_file_contents = "alpha two\n",
      tab_name = tab_name,
    }, function() end)

    assert.is_false(ok)
    assert.is_truthy(vim.inspect(err):find("E95", 1, true), vim.inspect(err))
  end)

  it("keeps the original buffer of a live new-file diff when a second diff opens the same new file", function()
    path = dir .. "/missing.txt"
    local diff, tools = load_plugin()
    assert.is_true(open_diff(tools, "first\n")._deferred)
    local first = diff._get_active_diffs()[tab_name]
    local original_name = vim.api.nvim_buf_get_name(first.original_buffer)
    close_old_diff_windows()

    local call = open_diff(tools, "second\n", tab_name .. " other")

    assert.is_nil(call._deferred)
    assert.is_truthy(vim.inspect(call.error):find("E95", 1, true), vim.inspect(call.error))
    assert.is_true(vim.api.nvim_buf_is_valid(first.original_buffer), "the live diff keeps its original buffer")
    assert.equal(original_name, vim.api.nvim_buf_get_name(first.original_buffer))
    assert.equal(first, diff._get_active_diffs()[tab_name], "the live diff stays registered")
  end)

  local foreign_buffers = {
    { name = "a listed buffer", listed = true, buftype = "" },
    { name = "a listed acwrite buffer", listed = true, buftype = "acwrite" },
    { name = "an unlisted nofile buffer", listed = false, buftype = "nofile" },
  }

  for _, foreign in ipairs(foreign_buffers) do
    it("keeps the E95 error for " .. foreign.name .. " under the proposal's name", function()
      local diff, tools = load_plugin()
      local owned = vim.api.nvim_create_buf(foreign.listed, false)
      vim.api.nvim_buf_set_name(owned, tab_name .. " (proposed)")
      vim.api.nvim_buf_set_option(owned, "buftype", foreign.buftype)
      vim.api.nvim_buf_set_lines(owned, 0, -1, false, { "the user's notes" })

      local call = open_diff(tools, "alpha\n")

      assert.is_nil(call._deferred)
      assert.is_truthy(vim.inspect(call.error):find("E95", 1, true), vim.inspect(call.error))
      assert.is_true(vim.api.nvim_buf_is_valid(owned), "the buffer is not wiped")
      assert.same({ "the user's notes" }, vim.api.nvim_buf_get_lines(owned, 0, -1, false))
      assert.is_nil(diff._get_active_diffs()[tab_name])
    end)
  end
end)

if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff with a leftover diff buffer under its name", function()
    pending("needs a real Neovim")
  end)
  return
end

-- No active diff owns a diff buffer that a reload (:Lazy reload) left loaded, or that a failed setup could not delete
-- in the command-line window. An openDiff for that tab name, in either layout, must open a diff. The leftover buffer
-- keeps its windows and text under another name, and its tab name no longer resolves the new diff.
describe("openDiff with a leftover diff buffer under its name", function()
  local dir
  local path
  local start_dir = vim.fn.getcwd()
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

  local function open_diff(tools, file_contents, name, file)
    local call = tools.handle_invoke({ id = "reload_proposal_name" }, {
      name = "openDiff",
      arguments = {
        old_file_path = file or path,
        new_file_path = file or path,
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
    vim.cmd("cd " .. vim.fn.fnameescape(start_dir))
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

  for _, layout in ipairs({ "vertical", "unified" }) do
    it("does not let the old window resolve the new diff after a :cd, with the " .. layout .. " layout", function()
      local _, tools = load_plugin(layout)
      assert.is_true(open_diff(tools, "alpha one\n")._deferred)
      local leftover = buffers_named(suffix_of(layout))[1]
      local diff
      diff, tools = load_plugin(layout)
      require("claudecode.diff_inline")
      vim.cmd("cd " .. vim.fn.fnameescape(vim.fn.fnamemodify(dir, ":h")))
      local call = open_diff(tools, "alpha two\n")
      assert.is_true(call._deferred, vim.inspect(call.error))
      local state = diff._get_active_diffs()[tab_name]

      local notify = vim.notify
      local messages = {}
      vim.notify = function(message)
        messages[#messages + 1] = message
      end
      vim.api.nvim_set_current_win(vim.fn.win_findbuf(leftover)[1])
      local ok, err = pcall(diff.accept_current_diff)
      vim.notify = notify

      assert.is_true(ok, err)
      assert.same({ "No active diff found in current buffer" }, messages)
      assert.equal("pending", state.status, "the new diff still waits for its own proposal window")
    end)
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

  it("closes no window when the original buffer of a new file cannot take its name", function()
    path = dir .. "/missing.txt"
    local _, tools = load_plugin()
    local foreign = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(foreign, path .. " (NEW FILE)")
    local windows = vim.api.nvim_tabpage_list_wins(0)
    local tabs = #vim.api.nvim_list_tabpages()

    local call = open_diff(tools, "alpha\n")

    assert.is_truthy(vim.inspect(call.error):find("E95", 1, true), vim.inspect(call.error))
    assert.equal(tabs, #vim.api.nvim_list_tabpages())
    for _, win in ipairs(windows) do
      assert.is_true(vim.api.nvim_win_is_valid(win), "no window that existed before the call closes")
    end
  end)

  it("keeps the name and the tab name of the proposal buffer of an active diff", function()
    local diff, tools = load_plugin()
    assert.is_true(open_diff(tools, "alpha one\n")._deferred)
    local active = diff._get_active_diffs()[tab_name]
    local seen
    local set_name = vim.api.nvim_buf_set_name
    vim.api.nvim_buf_set_name = function(buf, name)
      seen = seen or { binding = vim.b[active.new_buffer].claudecode_diff_tab_name }
      return set_name(buf, name)
    end

    local ok, err = pcall(diff._setup_blocking_diff, {
      old_file_path = path,
      new_file_path = path,
      new_file_contents = "alpha two\n",
      tab_name = tab_name,
    }, function() end)
    vim.api.nvim_buf_set_name = set_name

    assert.is_false(ok)
    assert.is_truthy(vim.inspect(err):find("E95", 1, true), vim.inspect(err))
    assert.equal(tab_name, seen.binding, "the second setup left the active diff's tab name alone")
  end)

  local function silence_notify(fn)
    local notify = vim.notify
    vim.notify = function() end
    local ok, err = pcall(fn)
    vim.notify = notify
    assert(ok, err)
  end

  local function show_another_file()
    vim.fn.writefile({ "x" }, dir .. "/other.txt")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
  end

  local function unsaved_user_work(win)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "UNSAVED USER WORK" })
    return buf
  end

  local function assert_user_work_kept(buf)
    assert.is_true(vim.api.nvim_buf_is_valid(buf), "the user's buffer stays")
    assert.same({ "UNSAVED USER WORK" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end

  local function reject_nested_open(trigger, layout)
    local _, tools = load_plugin(layout)
    local suffix = layout == "unified" and "(unified diff)" or "(proposed)"
    local nested
    local fired = false
    local group = vim.api.nvim_create_augroup("LeftoverNestedOpen", { clear = true })
    vim.api.nvim_create_autocmd(trigger, {
      group = group,
      callback = function(event)
        local bound = trigger == "FileType" and vim.b[event.buf].claudecode_inline_diff
        local named = vim.api.nvim_buf_get_name(event.buf):find(suffix, 1, true)
        if fired or not (bound or named) then
          return
        end
        fired = true
        vim.schedule(function()
          nested = open_diff(tools, "alpha two\n")
        end)
        vim.wait(200, function()
          return nested ~= nil
        end, 10)
      end,
    })
    local first
    silence_notify(function()
      first = open_diff(tools, "alpha one\n")
    end)
    vim.api.nvim_del_augroup_by_id(group)
    return first, nested, suffix
  end

  local nested_orders = {
    { trigger = "BufEnter", layout = "vertical" },
    { trigger = "BufEnter", layout = "unified" },
    { trigger = "FileType", layout = "unified" },
  }

  local function it_when(runs, name, fn)
    if runs then
      it(name, fn)
    else
      pending(name .. " (needs Neovim 0.9)")
    end
  end

  for _, order in ipairs(nested_orders) do
    it_when(
      order.trigger ~= "FileType" or vim.fn.has("nvim-0.9") == 1,
      "answers an openDiff for the same tab name that runs inside a setup and keeps that diff intact: "
        .. order.trigger
        .. ", "
        .. order.layout,
      function()
        local first, nested, suffix = reject_nested_open(order.trigger, order.layout)

        assert.is_not_nil(nested, "the second openDiff ran inside the first setup")
        assert.is_nil(nested._deferred)
        assert.is_truthy(vim.inspect(nested.error):find("Diff tab in use", 1, true), vim.inspect(nested.error))
        assert.is_true(first._deferred, vim.inspect(first.error))
        local diff = require("claudecode.diff")
        local state = diff._get_active_diffs()[tab_name]
        assert.same({ state.new_buffer }, buffers_named(suffix), "the first diff keeps the name of its buffer")
        assert.equal(tab_name, vim.b[state.new_buffer].claudecode_diff_tab_name)

        vim.api.nvim_set_current_win(vim.fn.win_findbuf(state.new_buffer)[1])
        diff.accept_current_diff()
        assert.equal("saved", state.status, "the user's accept in the first diff's window resolves it")
      end
    )
  end

  it_when(
    vim.fn.has("nvim-0.9") == 1,
    "lets an openDiff for the same tab name that a ClaudeCodeDiffOpened handler runs replace the diff",
    function()
      local diff, tools = load_plugin()
      local nested
      local group = vim.api.nvim_create_augroup("LeftoverDiffOpened", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "ClaudeCodeDiffOpened",
        once = true,
        callback = function()
          vim.schedule(function()
            nested = open_diff(tools, "alpha two\n")
          end)
          vim.wait(200, function()
            return nested ~= nil
          end, 10)
        end,
      })

      local first
      silence_notify(function()
        first = open_diff(tools, "alpha one\n")
      end)
      vim.api.nvim_del_augroup_by_id(group)

      assert.is_nil(first.error, vim.inspect(first.error))
      assert.is_not_nil(first.result, "the replaced diff is answered at once")
      assert.is_not_nil(nested, "the second openDiff ran inside the first one's event")
      assert.is_true(nested._deferred, vim.inspect(nested.error))
      assert.equal("alpha two\n", diff._get_active_diffs()[tab_name].new_file_contents)
    end
  )

  for _, trigger in ipairs({ "edit_e37", "newfile_e95" }) do
    it(
      "keeps a window that a user handler opened during the split when the original buffer fails: " .. trigger,
      function()
        vim.fn.writefile({ "x" }, dir .. "/other.txt")
        vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
        local _, tools = load_plugin()
        if trigger == "newfile_e95" then
          path = dir .. "/missing.txt"
          vim.api.nvim_buf_set_name(vim.api.nvim_create_buf(true, false), path .. " (NEW FILE)")
        end
        local start_win = vim.api.nvim_get_current_win()
        local user_win, user_buf
        vim.api.nvim_create_autocmd("WinNew", {
          once = true,
          callback = function()
            vim.cmd("noautocmd belowright split")
            user_win = vim.api.nvim_get_current_win()
            user_buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_name(user_buf, dir .. "/user-work.txt")
            vim.api.nvim_win_set_buf(user_win, user_buf)
            vim.bo[user_buf].bufhidden = "wipe"
            vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { "UNSAVED USER WORK" })
          end,
        })

        local call
        silence_notify(function()
          call = open_diff(tools, "proposed\n")
        end)

        assert.is_nil(call._deferred)
        assert.is_truthy(
          vim.inspect(call.error):find(trigger == "edit_e37" and "E37" or "E95", 1, true),
          vim.inspect(call.error)
        )
        assert.is_true(vim.api.nvim_win_is_valid(start_win), "the window that the diff started from stays")
        assert.is_true(vim.api.nvim_win_is_valid(user_win), "the user's window stays")
        assert.is_true(vim.api.nvim_buf_is_valid(user_buf), "the user's buffer stays")
        assert.same({ "UNSAVED USER WORK" }, vim.api.nvim_buf_get_lines(user_buf, 0, -1, false))
      end
    )
  end

  it("keeps a user's window when its handler closed the window that the split created", function()
    vim.fn.writefile({ "x" }, dir .. "/other.txt")
    vim.fn.writefile({ "original" }, dir .. "/reload.txt")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
    local _, tools = load_plugin()
    local user_win, user_buf
    vim.api.nvim_create_autocmd("WinNew", {
      once = true,
      callback = function()
        local plugin_win = vim.api.nvim_get_current_win()
        vim.cmd("noautocmd belowright split")
        user_win = vim.api.nvim_get_current_win()
        user_buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(user_buf, dir .. "/user-work.txt")
        vim.api.nvim_win_set_buf(user_win, user_buf)
        vim.bo[user_buf].bufhidden = "wipe"
        vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { "UNSAVED USER WORK" })
        vim.api.nvim_win_close(plugin_win, true)
      end,
    })

    local call
    silence_notify(function()
      call = open_diff(tools, "proposed\n")
    end)

    assert.is_nil(call._deferred)
    assert.is_truthy(vim.inspect(call.error):find("E37", 1, true), vim.inspect(call.error))
    assert.is_true(vim.api.nvim_win_is_valid(user_win), "the user's window stays")
    assert.same({ "UNSAVED USER WORK" }, vim.api.nvim_buf_get_lines(user_buf, 0, -1, false))
  end)

  it(
    "keeps a user's window and its unsaved text when a handler closed the split's window and a later one raises",
    function()
      show_another_file()
      local _, tools = load_plugin()
      local user_win, user_buf
      vim.api.nvim_create_autocmd("WinNew", {
        once = true,
        callback = function()
          local plugin_win = vim.api.nvim_get_current_win()
          vim.cmd("noautocmd belowright split")
          user_win = vim.api.nvim_get_current_win()
          vim.api.nvim_win_close(plugin_win, true)
        end,
      })
      vim.api.nvim_create_autocmd("BufEnter", {
        pattern = path,
        once = true,
        callback = function()
          user_buf = unsaved_user_work(user_win)
          error("the user's handler refuses the file")
        end,
      })

      local call
      silence_notify(function()
        call = open_diff(tools, "alpha\n")
      end)

      assert.is_nil(call._deferred)
      assert.is_truthy(vim.inspect(call.error):find("refuses the file", 1, true), vim.inspect(call.error))
      assert.is_true(vim.api.nvim_win_is_valid(user_win), "the user's window stays")
      assert_user_work_kept(user_buf)
    end
  )

  it("keeps the unsaved text that a handler put into the split's window before it raised", function()
    show_another_file()
    local _, tools = load_plugin()
    local split_win, user_buf
    vim.api.nvim_create_autocmd("BufEnter", {
      pattern = path,
      once = true,
      callback = function()
        split_win = vim.api.nvim_get_current_win()
        user_buf = unsaved_user_work(split_win)
        error("the user's handler refuses the file")
      end,
    })

    local call
    silence_notify(function()
      call = open_diff(tools, "alpha\n")
    end)

    assert.is_nil(call._deferred)
    assert.is_truthy(vim.inspect(call.error):find("refuses the file", 1, true), vim.inspect(call.error))
    assert.is_true(vim.api.nvim_win_is_valid(split_win), "the window that holds the user's text stays")
    assert_user_work_kept(user_buf)
  end)

  it("closes no window when a handler raises after the original buffer loaded into the split", function()
    show_another_file()
    local _, tools = load_plugin()
    local windows = vim.api.nvim_tabpage_list_wins(0)
    local split_win
    vim.api.nvim_create_autocmd("BufEnter", {
      pattern = path,
      once = true,
      callback = function()
        split_win = vim.api.nvim_get_current_win()
        error("the user's handler refuses the file")
      end,
    })

    local call
    silence_notify(function()
      call = open_diff(tools, "alpha\n")
    end)

    assert.is_nil(call._deferred)
    assert.is_truthy(vim.inspect(call.error):find("refuses the file", 1, true), vim.inspect(call.error))
    assert.is_true(vim.api.nvim_win_is_valid(split_win), "the window that the split created stays")
    for _, win in ipairs(windows) do
      assert.is_true(vim.api.nvim_win_is_valid(win), "no window that existed before the call closes")
    end
  end)

  it("keeps a window that a user handler opened on the cloned buffer during the split", function()
    vim.fn.writefile({ "x" }, dir .. "/other.txt")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
    local _, tools = load_plugin()
    path = dir .. "/missing.txt"
    vim.api.nvim_buf_set_name(vim.api.nvim_create_buf(true, false), path .. " (NEW FILE)")
    local user_win
    vim.api.nvim_create_autocmd("WinNew", {
      once = true,
      callback = function()
        vim.cmd("noautocmd belowright split")
        user_win = vim.api.nvim_get_current_win()
      end,
    })

    local call
    silence_notify(function()
      call = open_diff(tools, "proposed\n")
    end)

    assert.is_truthy(vim.inspect(call.error):find("E95", 1, true), vim.inspect(call.error))
    assert.is_true(vim.api.nvim_win_is_valid(user_win), "the user's window stays")
  end)

  it("closes no window when the original buffer fails to load in a reused window", function()
    local file_buffer = vim.fn.bufnr(path)
    vim.cmd("enew")
    vim.cmd("vsplit")
    vim.cmd("bunload " .. file_buffer)
    local _, tools = load_plugin()
    vim.api.nvim_create_autocmd("BufReadPre", {
      pattern = path,
      callback = function()
        error("the user's handler refuses the file")
      end,
    })
    local windows = #vim.api.nvim_tabpage_list_wins(0)

    local call
    silence_notify(function()
      call = open_diff(tools, "alpha\n")
    end)

    assert.is_nil(call._deferred)
    assert.is_truthy(vim.inspect(call.error):find("refuses the file", 1, true), vim.inspect(call.error))
    assert.equal(windows, #vim.api.nvim_tabpage_list_wins(0), "no window closes")
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

  local function open_recording(tools, key, file, contents, answers)
    local call = tools.handle_invoke({ id = "reload_proposal_name" }, {
      name = "openDiff",
      arguments = { old_file_path = file, new_file_path = file, new_file_contents = contents, tab_name = tab_name },
    })
    answers[key] = answers[key] or {}
    if call._deferred then
      _G.claude_deferred_responses[tostring(call.coroutine)] = function(result)
        table.insert(answers[key], result)
      end
    else
      table.insert(answers[key], call.result or call.error)
    end
    return call
  end

  local function leftover_of_a_reloaded_diff(layout, file)
    local _, tools = load_plugin(layout)
    assert.is_true(open_diff(tools, "alpha zero\n", nil, file)._deferred)
    return load_plugin(layout)
  end

  local function proposal_buffer_showing(text)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      if #vim.fn.win_findbuf(buf) > 0 and lines:find(text, 1, true) then
        return buf
      end
    end
  end

  local function accept_proposal_showing(diff, text)
    local shown = proposal_buffer_showing(text)
    assert.is_not_nil(shown, "a window shows " .. text)
    silence_notify(function()
      vim.api.nvim_set_current_win(vim.fn.win_findbuf(shown)[1])
      diff.accept_current_diff()
    end)
  end

  local function assert_refused(call, answers, key)
    assert.is_nil(call._deferred, "the refused call is answered at once")
    assert.is_truthy(vim.inspect(call.error):find("Diff tab in use", 1, true), vim.inspect(call.error))
    assert.equal(1, #answers[key], "the refused call " .. key .. " is answered once")
    assert.is_truthy(vim.inspect(answers[key][1]):find("Diff tab in use", 1, true), vim.inspect(answers[key][1]))
  end

  -- A user handler runs the event loop while the first openDiff sets up, and Claude's queued calls for the same tab
  -- name run inside it. A leftover buffer of a reloaded diff holds the first call's proposal name, so the setup frees
  -- the name by a rename that fires BufFilePre, BufFilePost and BufWipeout.
  local function run_queued_calls(order)
    local diff, tools = leftover_of_a_reloaded_diff(order.layout, order.first)
    local answers, calls = {}, {}
    local fired = false
    local function open_queued()
      for _, queued in ipairs(order.queued) do
        calls[queued.key] = open_recording(tools, queued.key, queued.file, queued.key .. " PROPOSAL\n", answers)
      end
    end
    local last = order.queued[#order.queued].key
    local group = vim.api.nvim_create_augroup("LeftoverQueuedCalls", { clear = true })
    vim.api.nvim_create_autocmd(order.event, {
      group = group,
      callback = function(args)
        if fired or (order.filter and not order.filter(vim.api.nvim_buf_get_name(args.buf))) then
          return
        end
        fired = true
        vim.schedule(open_queued)
        vim.wait(500, function()
          return calls[last] ~= nil
        end, 10)
      end,
    })
    silence_notify(function()
      calls.A = open_recording(tools, "A", order.first, "A PROPOSAL\n", answers)
    end)
    vim.api.nvim_del_augroup_by_id(group)
    assert.is_true(fired, "the handler ran inside the first setup")
    return diff, answers, calls
  end

  local function name_has(suffix)
    return function(name)
      return name:find(suffix, 1, true) ~= nil
    end
  end

  local function queued_pair(second_file)
    return { { key = "B", file = second_file } }
  end

  local function with_files(fn)
    return function()
      vim.fn.mkdir(dir .. "/a", "p")
      vim.fn.mkdir(dir .. "/b", "p")
      vim.fn.writefile({ "return 'b'" }, dir .. "/b/util.lua")
      vim.fn.writefile({ "beta" }, dir .. "/b.txt")
      fn()
    end
  end

  local refusal_orders = {
    {
      name = "a BufFilePost handler, split layout, existing files",
      event = "BufFilePost",
      layout = "vertical",
      first = function()
        return path
      end,
      second = function()
        return dir .. "/b.txt"
      end,
    },
    {
      name = "a BufFilePre handler, split layout, the same file",
      event = "BufFilePre",
      layout = "vertical",
      first = function()
        return path
      end,
      second = function()
        return path
      end,
    },
    {
      name = "a BufNew handler, split layout, the same file",
      event = "BufNew",
      layout = "vertical",
      first = function()
        return path
      end,
      second = function()
        return path
      end,
    },
    {
      name = "a BufWipeout handler, split layout, a new file then an existing file",
      event = "BufWipeout",
      layout = "vertical",
      filter = name_has(tab_name),
      first = function()
        return dir .. "/a/util.lua"
      end,
      second = function()
        return dir .. "/b/util.lua"
      end,
    },
    {
      name = "a BufWipeout handler, unified layout, a new file then an existing file",
      event = "BufWipeout",
      layout = "unified",
      filter = name_has(tab_name),
      first = function()
        return dir .. "/a/util.lua"
      end,
      second = function()
        return dir .. "/b/util.lua"
      end,
    },
    {
      name = "a BufEnter handler after the first named its buffer, split layout, an existing file then a new file",
      event = "BufEnter",
      layout = "vertical",
      filter = name_has("(proposed)"),
      first = function()
        return path
      end,
      second = function()
        return dir .. "/brand-new.txt"
      end,
    },
    {
      name = "a BufEnter handler after the first named its buffer, unified layout, an existing file then a new file",
      event = "BufEnter",
      layout = "unified",
      filter = name_has("(unified diff)"),
      first = function()
        return path
      end,
      second = function()
        return dir .. "/brand-new.txt"
      end,
    },
  }

  for _, order in ipairs(refusal_orders) do
    it(
      "refuses the second openDiff, answers each call once and serves the first with its own text: " .. order.name,
      with_files(function()
        local diff, answers, calls = run_queued_calls({
          event = order.event,
          layout = order.layout,
          filter = order.filter,
          first = order.first(),
          queued = queued_pair(order.second()),
        })

        assert.is_true(calls.A._deferred, vim.inspect(calls.A.error))
        assert_refused(calls.B, answers, "B")
        accept_proposal_showing(diff, "A PROPOSAL")
        assert.equal(1, #answers.A, "the first call is answered once")
        assert.equal("FILE_SAVED", answers.A[1].content[1].text)
        assert.equal("A PROPOSAL\n", answers.A[1].content[2].text, "the first call gets its own text")
        assert.equal(1, #answers.B, "the refused call is not answered again")
      end)
    )
  end

  it(
    "refuses the second and the third openDiff that run inside the first setup, in the unified layout",
    with_files(function()
      local diff, answers, calls = run_queued_calls({
        event = "BufEnter",
        layout = "unified",
        filter = name_has("(unified diff)"),
        first = path,
        queued = { { key = "B", file = dir .. "/brand-new.txt" }, { key = "C", file = dir .. "/b.txt" } },
      })

      assert.is_true(calls.A._deferred, vim.inspect(calls.A.error))
      assert_refused(calls.B, answers, "B")
      assert_refused(calls.C, answers, "C")
      accept_proposal_showing(diff, "A PROPOSAL")
      assert.equal(1, #answers.A, "the first call is answered once")
      assert.equal("A PROPOSAL\n", answers.A[1].content[2].text, "the first call gets its own text")
      assert.equal(1, #answers.B)
      assert.equal(1, #answers.C)
    end)
  )

  for _, layout in ipairs({ "vertical", "unified" }) do
    for _, partial in ipairs({ true, false }) do
      it(
        "refuses a second openDiff and keeps the first diff's buffer when a plugin reload of "
          .. (partial and "the diff module" or "every claudecode module")
          .. " runs inside the first setup: "
          .. layout,
        function()
          local _, tools = load_plugin(layout)
          local suffix = layout == "unified" and "(unified diff)" or "(proposed)"
          local answers, first_buffer, second, fired = {}, nil, nil, false
          local group = vim.api.nvim_create_augroup("LeftoverReloadInSetup", { clear = true })
          vim.api.nvim_create_autocmd("BufEnter", {
            group = group,
            callback = function(args)
              if fired or not vim.api.nvim_buf_get_name(args.buf):find(suffix, 1, true) then
                return
              end
              fired = true
              first_buffer = args.buf
              vim.schedule(function()
                local reloaded
                if partial then
                  package.loaded["claudecode.diff"] = nil
                  require("claudecode.diff").setup({ terminal = { provider = "none" }, diff_opts = { layout = layout } })
                  reloaded = require("claudecode.tools.init")
                else
                  _, reloaded = load_plugin(layout)
                end
                second = open_recording(reloaded, "B", path, "B PROPOSAL\n", answers)
              end)
              vim.wait(1000, function()
                return second ~= nil
              end, 10)
            end,
          })
          local first
          silence_notify(function()
            first = open_recording(tools, "A", path, "A PROPOSAL\n", answers)
          end)
          vim.api.nvim_del_augroup_by_id(group)

          assert.is_true(fired, "the reload ran inside the first setup")
          assert.is_true(first._deferred, vim.inspect(first.error))
          assert_refused(second, answers, "B")
          assert.is_nil(
            vim.api.nvim_buf_get_name(first_buffer):find("(orphaned", 1, true),
            "the first buffer keeps its name"
          )
          assert.equal(tab_name, vim.b[first_buffer].claudecode_diff_tab_name, "the first buffer keeps its tab name")

          silence_notify(function()
            vim.api.nvim_set_current_win(vim.fn.win_findbuf(first_buffer)[1])
            vim.cmd("ClaudeCodeDiffAccept")
          end)
          assert.equal(1, #answers.B, "the accept in the first diff's window does not answer the second call")
          assert.is_truthy(vim.inspect(answers.B[1]):find("Diff tab in use", 1, true), vim.inspect(answers.B[1]))
        end
      )
    end
  end

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

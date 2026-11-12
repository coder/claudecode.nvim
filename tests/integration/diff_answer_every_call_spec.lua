if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff answers every call", function()
    pending("needs a real Neovim")
  end)
  return
end

-- Two openDiff calls for one tab name can overlap when a handler of the user runs the event loop (vim.wait), because
-- Claude's queued call then runs inside it. Each call must still get exactly one answer, with its own text, and no
-- window or tab of the first call may stay behind. Two orders lost an answer:
--   1. A ClaudeCodeDiffClosed handler runs while an openDiff replaces the old diff, and the queued call registers a
--      diff for the tab name before the replacing call sets up its own.
--   2. A plugin reload runs inside a setup. The diff of that setup then lives in the old module, and no command of
--      the new module (accept, deny, close-all) can answer it.
describe("openDiff answers every call", function()
  local dir
  local tab_name = "✻ [Claude Code] overlap ⧉"

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
      diff_opts = { layout = layout },
    })
    local tools = require("claudecode.tools.init")
    tools.register_all()
    return require("claudecode.diff"), tools
  end

  local function silence_notify(fn)
    local notify = vim.notify
    vim.notify = function() end
    local ok, err = pcall(fn)
    vim.notify = notify
    assert(ok, err)
  end

  -- Open a diff and record every answer the call gets. A call that is not deferred got its answer at once.
  local function open_recording(tools, key, file, answers)
    local call = tools.handle_invoke({ id = "overlap_" .. key }, {
      name = "openDiff",
      arguments = {
        old_file_path = file,
        new_file_path = file,
        new_file_contents = key .. " PROPOSAL\n",
        tab_name = tab_name,
      },
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

  local function kind_of(result)
    local content = result.content
    if content and content[1] then
      return content[1].text
    end
    return vim.inspect(result):find("E95", 1, true) and "E95" or "error"
  end

  local function assert_answered_once(answers, key, kind, own_text)
    assert.equal(1, #answers[key], "the call " .. key .. " is answered once: " .. vim.inspect(answers[key]))
    assert.equal(kind, kind_of(answers[key][1]), "the answer of " .. key)
    if own_text then
      assert.equal(own_text, answers[key][1].content[2].text, "the call " .. key .. " gets its own text")
    end
  end

  local function accept_proposal_showing(diff, text)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      if #vim.fn.win_findbuf(buf) > 0 and lines:find(text, 1, true) then
        silence_notify(function()
          vim.api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
          diff.accept_current_diff()
        end)
        return
      end
    end
    error("no window shows " .. text)
  end

  local function close_all()
    silence_notify(function()
      vim.cmd("ClaudeCodeCloseAllDiffs")
    end)
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    for _, name in ipairs({ "a.txt", "b.txt", "x.txt" }) do
      vim.fn.writefile({ "original " .. name }, dir .. "/" .. name)
    end
    _G.claude_deferred_responses = {}
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
  end)

  after_each(function()
    vim.api.nvim_create_augroup("OverlapSpec", { clear = true })
    pcall(function()
      require("claudecode.diff")._cleanup_all_active_diffs("test cleanup")
    end)
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  for _, layout in ipairs({ "vertical", "unified" }) do
    for _, replaced_is_new_file in ipairs({ true, false }) do
      it(
        "answers a call that a ClaudeCodeDiffClosed handler lets register while the old "
          .. (replaced_is_new_file and "new-file" or "existing-file")
          .. " diff is replaced: "
          .. layout,
        function()
          local diff, tools = load_plugin(layout)
          local answers = {}
          local windows, tabs = #vim.api.nvim_tabpage_list_wins(0), #vim.api.nvim_list_tabpages()
          local replaced_file = replaced_is_new_file and dir .. "/missing.txt" or dir .. "/x.txt"
          assert.is_true(open_recording(tools, "X", replaced_file, answers)._deferred)

          local queued
          vim.api.nvim_create_autocmd("User", {
            group = vim.api.nvim_create_augroup("OverlapSpec", { clear = true }),
            pattern = "ClaudeCodeDiffClosed",
            once = true,
            callback = function()
              vim.schedule(function()
                queued = open_recording(tools, "B", dir .. "/b.txt", answers)
              end)
              vim.wait(1000, function()
                return queued ~= nil
              end, 10)
            end,
          })
          local replacing
          silence_notify(function()
            replacing = open_recording(tools, "A", dir .. "/a.txt", answers)
          end)

          assert.is_not_nil(queued, "the second call ran inside the close event")
          assert.is_true(replacing._deferred, vim.inspect(replacing.error))
          assert_answered_once(answers, "X", "DIFF_REJECTED")
          assert_answered_once(answers, "B", "DIFF_REJECTED")
          assert.same({}, answers.A, "the call A waits for the user")

          accept_proposal_showing(diff, "A PROPOSAL")
          assert_answered_once(answers, "A", "FILE_SAVED", "A PROPOSAL\n")
          close_all()
          assert.equal(tabs, #vim.api.nvim_list_tabpages(), "no extra tab stays")
          assert.equal(windows, #vim.api.nvim_tabpage_list_wins(0), "no window of a diff stays")
          assert_answered_once(answers, "A", "FILE_SAVED", "A PROPOSAL\n")
          assert_answered_once(answers, "B", "DIFF_REJECTED")
        end
      )
    end
  end

  -- A user handler reloads the plugin and runs Claude's queued second call while the first call sets up.
  local function reload_inside_setup(layout, partial, second_file)
    local diff_before, tools = load_plugin(layout)
    local suffix = layout == "unified" and "(unified diff)" or "(proposed)"
    local answers, second, fired = {}, nil, false
    local group = vim.api.nvim_create_augroup("OverlapSpec", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      callback = function(args)
        if fired or not vim.api.nvim_buf_get_name(args.buf):find(suffix, 1, true) then
          return
        end
        fired = true
        vim.schedule(function()
          local reloaded
          if partial then
            package.loaded["claudecode.diff"] = nil
            require("claudecode.diff").setup({ terminal = { provider = "none" }, diff_opts = { layout = layout } })
            reloaded = require("claudecode.tools.init")
          else
            _, reloaded = load_plugin(layout)
          end
          second = open_recording(reloaded, "B", second_file, answers)
        end)
        vim.wait(1000, function()
          return second ~= nil
        end, 10)
      end,
    })
    local first
    silence_notify(function()
      first = open_recording(tools, "A", dir .. "/a.txt", answers)
    end)
    vim.api.nvim_del_augroup_by_id(group)
    assert.is_true(fired, "the reload ran inside the first setup")
    assert.is_not_equal(diff_before, require("claudecode.diff"), "the diff module was reloaded")
    return require("claudecode.diff"), answers, first, second
  end

  local reload_orders = {
    { layout = "vertical", partial = false, second_file = "a.txt", second = "E95" },
    { layout = "vertical", partial = true, second_file = "a.txt", second = "E95" },
    { layout = "vertical", partial = false, second_file = "missing.txt", second = "DIFF_REJECTED" },
    { layout = "unified", partial = false, second_file = "a.txt", second = "DIFF_REJECTED" },
    { layout = "unified", partial = true, second_file = "a.txt", second = "DIFF_REJECTED" },
  }

  for _, order in ipairs(reload_orders) do
    it(
      "answers the first call that a plugin reload inside its setup left in the old module: "
        .. order.layout
        .. ", "
        .. (order.partial and "the diff module" or "every claudecode module")
        .. ", the second call for "
        .. order.second_file,
      function()
        local windows, tabs = #vim.api.nvim_tabpage_list_wins(0), #vim.api.nvim_list_tabpages()
        local diff, answers, first, second =
          reload_inside_setup(order.layout, order.partial, dir .. "/" .. order.second_file)

        assert.is_true(first._deferred, vim.inspect(first.error))
        assert.is_not_nil(second)
        accept_proposal_showing(diff, "A PROPOSAL")
        assert_answered_once(answers, "A", "FILE_SAVED", "A PROPOSAL\n")
        close_all()
        assert_answered_once(answers, "B", order.second)
        assert_answered_once(answers, "A", "FILE_SAVED", "A PROPOSAL\n")
        assert.equal(tabs, #vim.api.nvim_list_tabpages(), "no extra tab stays")
        assert.equal(windows, #vim.api.nvim_tabpage_list_wins(0), "no window of a diff stays")
      end
    )
  end

  it("answers the first call once when the user writes its proposal after a reload inside its setup", function()
    local diff, answers, first = reload_inside_setup("vertical", false, dir .. "/a.txt")

    assert.is_true(first._deferred, vim.inspect(first.error))
    local shown
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if #vim.fn.win_findbuf(buf) > 0 and vim.bo[buf].buftype == "acwrite" then
        shown = buf
      end
    end
    assert.is_not_nil(shown, "the proposal is shown")
    silence_notify(function()
      vim.api.nvim_set_current_win(vim.fn.win_findbuf(shown)[1])
      vim.cmd("write")
      close_all()
      diff.close_saved_diffs("spec")
    end)

    assert_answered_once(answers, "A", "FILE_SAVED", "A PROPOSAL\n")
  end)

  it("keeps a diff that the new module already answered when an older module registers one", function()
    local old_diff = load_plugin("vertical")
    local diff, tools = load_plugin("vertical")
    local answers = {}
    assert.is_true(open_recording(tools, "B", dir .. "/b.txt", answers)._deferred)
    accept_proposal_showing(diff, "B PROPOSAL")
    local kept = diff._get_active_diffs()[tab_name]
    assert.equal("saved", kept.status)

    local late = { status = "pending", new_file_contents = "late\n" }
    old_diff._register_diff_state(tab_name, late)

    assert.equal(kept, diff._get_active_diffs()[tab_name], "the answered diff stays registered")
    assert.equal(late, old_diff._get_active_diffs()[tab_name], "the old module keeps its own state")
    old_diff._get_active_diffs()[tab_name] = nil
  end)
end)

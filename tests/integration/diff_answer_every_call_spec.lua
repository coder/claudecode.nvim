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
    tools.setup()
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

  -- Count the open and close events of each diff, by file name.
  local function watch_events()
    local counts = {}
    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("OverlapSpecEvents", { clear = true }),
      pattern = { "ClaudeCodeDiffOpened", "ClaudeCodeDiffClosed" },
      callback = function(args)
        local file = vim.fn.fnamemodify(args.data.file_path, ":t")
        counts[file] = counts[file] or { opened = 0, closed = 0 }
        local kind = args.match == "ClaudeCodeDiffOpened" and "opened" or "closed"
        counts[file][kind] = counts[file][kind] + 1
      end,
    })
    return counts
  end

  -- A statusline that counts open diffs (+1 on open, -1 on close) must end at 0, and no diff closes twice.
  local function assert_events_paired(counts)
    for file, count in pairs(counts) do
      assert.equal(
        count.opened,
        count.closed,
        "the open and close events of " .. file .. " pair: " .. vim.inspect(count)
      )
    end
  end

  local function proposal_window(text)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local lines = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      if #vim.fn.win_findbuf(buf) > 0 and lines:find(text, 1, true) then
        return vim.fn.win_findbuf(buf)[1]
      end
    end
    error("no window shows " .. text)
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
    vim.api.nvim_create_augroup("OverlapSpecClosed", { clear = true })
    vim.api.nvim_create_augroup("OverlapSpecEvents", { clear = true })
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
  local function reload_inside_setup(layout, partial, second_file, answers)
    local diff_before, tools = load_plugin(layout)
    local suffix = layout == "unified" and "(unified diff)" or "(proposed)"
    answers = answers or {}
    local second, fired = nil, false
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
            reloaded = select(2, load_plugin(layout))
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
    return require("claudecode.diff"), answers, first, second, diff_before
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
        local counts = watch_events()
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
        assert_events_paired(counts)
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

  it(
    "rejects a third call that registers while the new module rejects the second one for the late first call",
    function()
      local answers = {}
      vim.api.nvim_create_autocmd("User", {
        group = vim.api.nvim_create_augroup("OverlapSpecClosed", { clear = true }),
        pattern = "ClaudeCodeDiffClosed",
        once = true,
        callback = function()
          local third
          vim.schedule(function()
            third = open_recording(require("claudecode.tools.init"), "C", dir .. "/b.txt", answers)
          end)
          vim.wait(1000, function()
            return third ~= nil
          end, 10)
        end,
      })

      local diff, _, first, second = reload_inside_setup("unified", false, dir .. "/a.txt", answers)

      assert.is_true(first._deferred, vim.inspect(first.error))
      assert.is_not_nil(second)
      assert.equal(
        "A PROPOSAL\n",
        diff._get_active_diffs()[tab_name].new_file_contents,
        "the first call takes the tab name"
      )
      accept_proposal_showing(diff, "A PROPOSAL")
      assert_answered_once(answers, "A", "FILE_SAVED", "A PROPOSAL\n")
      assert_answered_once(answers, "B", "DIFF_REJECTED")
      assert_answered_once(answers, "C", "DIFF_REJECTED")
    end
  )

  for _, layout in ipairs({ "vertical", "unified" }) do
    it(
      "closes the late first call once, with its open event first, when a handler reloads the plugin again while the "
        .. "second module rejects the second call: "
        .. layout,
      function()
        local answers, events, kept, second_module = {}, {}, nil, nil
        local group = vim.api.nvim_create_augroup("OverlapSpecClosed", { clear = true })
        vim.api.nvim_create_autocmd("User", {
          group = group,
          pattern = { "ClaudeCodeDiffOpened", "ClaudeCodeDiffClosed" },
          callback = function(args)
            table.insert(events, args.match .. ":" .. vim.fn.fnamemodify(args.data.file_path, ":t"))
          end,
        })
        vim.api.nvim_create_autocmd("User", {
          group = group,
          pattern = "ClaudeCodeDiffClosed",
          once = true,
          callback = function()
            second_module = package.loaded["claudecode.diff"]
            vim.schedule(function()
              local third_diff, third_tools = load_plugin(layout)
              open_recording(third_tools, "C", dir .. "/missing.txt", answers)
              accept_proposal_showing(third_diff, "C PROPOSAL")
              kept = third_diff
            end)
            vim.wait(1000, function()
              return kept ~= nil
            end, 10)
          end,
        })

        local _, _, first, second, original = reload_inside_setup(layout, false, dir .. "/missing.txt", answers)

        assert.is_not_nil(second)
        assert.is_not_nil(kept, "a handler reloaded the plugin a second time")
        assert.is_not_equal(original, kept, "the diff module was reloaded twice")
        assert.is_nil(first._deferred, "the first call is answered at once")
        assert_answered_once(answers, "A", "DIFF_REJECTED")
        assert_answered_once(answers, "B", "DIFF_REJECTED")
        assert_answered_once(answers, "C", "FILE_SAVED", "C PROPOSAL\n")
        assert.equal("saved", kept._get_active_diffs()[tab_name].status, "the accepted diff keeps the tab name")
        assert.is_nil(original._get_active_diffs()[tab_name], "the module of the late diff forgot it")
        assert.is_nil(second_module._get_active_diffs()[tab_name], "the second module forgot it")
        local first_events = vim.tbl_filter(function(event)
          return event:find("a.txt", 1, true) ~= nil
        end, events)
        assert.same(
          { "ClaudeCodeDiffOpened:a.txt", "ClaudeCodeDiffClosed:a.txt" },
          first_events,
          "the late diff closes once, and its open event comes first"
        )
      end
    )
  end

  for _, layout in ipairs({ "vertical", "unified" }) do
    it(
      "rejects the first call and keeps the second one that the user accepted before the first finished: " .. layout,
      function()
        local _, tools = load_plugin(layout)
        local suffix = layout == "unified" and "(unified diff)" or "(proposed)"
        local answers, accepted, second, fired, events = {}, nil, nil, false, {}
        vim.api.nvim_create_autocmd("User", {
          group = vim.api.nvim_create_augroup("OverlapSpecClosed", { clear = true }),
          pattern = { "ClaudeCodeDiffOpened", "ClaudeCodeDiffClosed" },
          callback = function(args)
            table.insert(events, args.match .. ":" .. vim.fn.fnamemodify(args.data.file_path, ":t"))
          end,
        })
        local group = vim.api.nvim_create_augroup("OverlapSpec", { clear = true })
        vim.api.nvim_create_autocmd("BufEnter", {
          group = group,
          callback = function(args)
            if fired or not vim.api.nvim_buf_get_name(args.buf):find(suffix, 1, true) then
              return
            end
            fired = true
            vim.schedule(function()
              local reloaded_diff, reloaded_tools = load_plugin(layout)
              second = open_recording(reloaded_tools, "B", dir .. "/missing.txt", answers)
              accept_proposal_showing(reloaded_diff, "B PROPOSAL")
              accepted = reloaded_diff
            end)
            vim.wait(1000, function()
              return accepted ~= nil
            end, 10)
          end,
        })
        local first
        silence_notify(function()
          first = open_recording(tools, "A", dir .. "/a.txt", answers)
        end)
        vim.api.nvim_del_augroup_by_id(group)

        assert.is_true(fired, "the reload ran inside the first setup")
        assert.is_nil(first._deferred, "the first call is answered at once")
        assert_answered_once(answers, "A", "DIFF_REJECTED")
        assert.is_true(second._deferred, vim.inspect(second.error))
        assert_answered_once(answers, "B", "FILE_SAVED", "B PROPOSAL\n")
        local kept = accepted._get_active_diffs()[tab_name]
        assert.equal("saved", kept.status, "the accepted diff stays registered")
        assert.is_true(vim.api.nvim_buf_is_valid(kept.new_buffer), "the accepted proposal stays")
        local first_events = vim.tbl_filter(function(event)
          return event:find("a.txt", 1, true) ~= nil
        end, events)
        assert.same(
          { "ClaudeCodeDiffOpened:a.txt", "ClaudeCodeDiffClosed:a.txt" },
          first_events,
          "the rejected call closes once, and no open event follows its close"
        )
      end
    )
  end

  -- A user handler reloads the plugin while openDiff A for a new file sets up. The diff of that setup is then tracked in
  -- both modules, and the user or Claude can end it from either one.
  local endings = {
    { name = "quit", cmd = "quit", answer = "DIFF_REJECTED" },
    { name = "bwipeout", cmd = "bwipeout!", answer = "DIFF_REJECTED" },
    { name = "deny", cmd = "ClaudeCodeDiffDeny", answer = "DIFF_REJECTED" },
    { name = "write", cmd = "write", answer = "FILE_SAVED" },
  }
  for _, layout in ipairs({ "vertical", "unified" }) do
    for _, synchronous in ipairs({ true, false }) do
      for _, ending in ipairs(endings) do
        it(
          "fires one open and one close event for a new file that a reload inside its setup left in two modules: "
            .. layout
            .. ", "
            .. (synchronous and "a reload that does not run the event loop" or "a reload inside the event loop")
            .. ", "
            .. ending.name
            .. " then close_tab",
          function()
            local counts, answers = watch_events(), {}
            local diff_before, tools = load_plugin(layout)
            local suffix = layout == "unified" and "(unified diff)" or "proposed)"
            local fired = false
            local group = vim.api.nvim_create_augroup("OverlapSpec", { clear = true })
            vim.api.nvim_create_autocmd("BufEnter", {
              group = group,
              callback = function(args)
                if fired or not vim.api.nvim_buf_get_name(args.buf):find(suffix, 1, true) then
                  return
                end
                fired = true
                if synchronous then
                  tools = select(2, load_plugin(layout))
                  return
                end
                local reloaded = false
                vim.schedule(function()
                  tools = select(2, load_plugin(layout))
                  reloaded = true
                end)
                vim.wait(1000, function()
                  return reloaded
                end, 10)
              end,
            })
            silence_notify(function()
              open_recording(tools, "A", dir .. "/new.txt", answers)
            end)
            vim.api.nvim_del_augroup_by_id(group)
            assert.is_true(fired, "the reload ran inside the setup")
            assert.is_not_equal(diff_before, require("claudecode.diff"), "the diff module was reloaded")

            silence_notify(function()
              vim.api.nvim_set_current_win(proposal_window("A PROPOSAL"))
              vim.cmd(ending.cmd)
            end)
            vim.wait(100)
            tools.handle_invoke({ id = "close_tab" }, { name = "close_tab", arguments = { tab_name = tab_name } })
            close_all()
            vim.wait(100)

            assert_answered_once(answers, "A", ending.answer)
            assert.same({ opened = 1, closed = 1 }, counts["new.txt"], "one open event and one close event")
            assert.is_nil(diff_before._get_active_diffs()[tab_name], "the old module forgot the diff")
            assert.is_nil(require("claudecode.diff")._get_active_diffs()[tab_name], "the new module forgot the diff")
          end
        )
      end
    end
  end

  it("rejects the late first call when the new module holds a second call that the user denied", function()
    local counts, answers = watch_events(), {}
    local windows, tabs = #vim.api.nvim_tabpage_list_wins(0), #vim.api.nvim_list_tabpages()
    local diff_before, tools = load_plugin("unified")
    local fired, second = false, nil
    local group = vim.api.nvim_create_augroup("OverlapSpec", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      callback = function(args)
        if fired or not vim.api.nvim_buf_get_name(args.buf):find("(unified diff)", 1, true) then
          return
        end
        fired = true
        vim.schedule(function()
          local _, reloaded = load_plugin("unified")
          second = open_recording(reloaded, "B", dir .. "/a.txt", answers)
          silence_notify(function()
            vim.api.nvim_set_current_win(proposal_window("B PROPOSAL"))
            vim.cmd("ClaudeCodeDiffDeny")
          end)
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
    assert.is_nil(first._deferred, "the first call is answered at once, as the new module holds an answered diff")
    assert_answered_once(answers, "A", "DIFF_REJECTED")
    assert_answered_once(answers, "B", "DIFF_REJECTED")
    close_all()
    assert.equal(tabs, #vim.api.nvim_list_tabpages(), "no extra tab stays")
    assert.equal(windows, #vim.api.nvim_tabpage_list_wins(0), "no window of a diff stays")
    assert_events_paired(counts)
  end)

  it("answers a call that registers while the new module rejects a second call that sits in an empty tab", function()
    local answers, reloaded_tools, fired, second, third = {}, nil, false, nil, nil
    local _, tools = load_plugin("vertical")
    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("OverlapSpecClosed", { clear = true }),
      pattern = "ClaudeCodeDiffClosed",
      once = true,
      callback = function()
        vim.schedule(function()
          third = open_recording(reloaded_tools, "C", dir .. "/missing.txt", answers)
        end)
        vim.wait(1000, function()
          return third ~= nil
        end, 10)
      end,
    })
    local group = vim.api.nvim_create_augroup("OverlapSpec", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      callback = function(args)
        if fired or not vim.api.nvim_buf_get_name(args.buf):find("(proposed)", 1, true) then
          return
        end
        fired = true
        vim.schedule(function()
          -- The new file of the second call then opens in an empty tab of the user, and its rejection cleans up at once.
          vim.cmd("noautocmd tabnew")
          reloaded_tools = select(2, load_plugin("vertical"))
          second = open_recording(reloaded_tools, "B", dir .. "/missing.txt", answers)
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
    assert.is_true(first._deferred, vim.inspect(first.error))
    assert.is_not_nil(third, "the close event of the second call ran the third call")
    assert_answered_once(answers, "B", "DIFF_REJECTED")
    assert_answered_once(answers, "C", "DIFF_REJECTED")
    assert.same({}, answers.A, "the first call waits for the user")
  end)
end)

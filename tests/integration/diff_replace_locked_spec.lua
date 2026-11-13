-- Real-Neovim checks of an openDiff that replaces an open diff (same tab_name) while Neovim refuses window changes
-- (the command-line window, E11, or text lock, E565). The replacing call fails with an error answer, the old diff
-- closes once windows can change, and the failed call leaves nothing behind: no window of the command-line window,
-- no proposal buffer, and no buffer name that blocks the next openDiff. Mock vim has neither lock, so under busted
-- this is pending; scripts/run_integration_tests_individually.sh runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("a replacing openDiff while Neovim refuses window changes", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("a replacing openDiff while Neovim refuses window changes", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local window_lock = require("tests.helpers.window_lock")
  local client = { id = "locked_replace_spec_client" }
  local tab_name = "✻ [Claude Code] shared ⧉"
  local dir, answers

  -- `kind` is "existing" (the file is on disk) or "new" (it is not). The sender stands in for the WebSocket reply of
  -- that one call. An error answer comes back at once, and the call is then no longer deferred.
  local function open_diff(label, kind)
    local path = dir .. "/" .. label .. "-" .. kind .. ".txt"
    if kind == "existing" then
      vim.fn.writefile({ "on disk" }, path)
    end
    answers[label] = {}
    local call = tools.handle_invoke(client, {
      name = "openDiff",
      arguments = {
        old_file_path = path,
        new_file_path = path,
        new_file_contents = label .. " proposal\n",
        tab_name = tab_name,
      },
    })
    if call._deferred then
      _G.claude_deferred_responses[tostring(call.coroutine)] = function(response)
        table.insert(answers[label], response)
      end
    else
      table.insert(answers[label], call.error or call.result)
    end
    return call
  end

  local function answer_texts(label)
    return vim.tbl_map(function(answer)
      return answer.content and answer.content[1].text or ("error " .. tostring(answer.code))
    end, answers[label])
  end

  local function buffers_of_the_plugin()
    local found = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name:find("Claude Code", 1, true) or vim.b[buf].claudecode_diff_tab_name ~= nil then
        found[#found + 1] = name
      end
    end
    return found
  end

  local function command_line_windows()
    local found = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find("[Command Line]", 1, true) then
        found[#found + 1] = win
      end
    end
    return found
  end

  before_each(function()
    vim.o.columns, vim.o.lines = 160, 40
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    tools.register_all()
    _G.claude_deferred_responses = {}
    answers = {}
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  for _, layout in ipairs({ "vertical", "unified" }) do
    for _, kinds in ipairs({ { "existing", "new" }, { "new", "existing" } }) do
      for _, lock in ipairs(window_lock.states) do
        describe(
          "in the "
            .. layout
            .. " layout, old diff of a "
            .. kinds[1]
            .. " file, new of a "
            .. kinds[2]
            .. " file, when "
            .. lock.name,
          function()
            -- The user is in another tab than the old diff, as in a second tab after :tabnew.
            local function replace_while_locked()
              diff.setup({ terminal = { provider = "none" }, diff_opts = { layout = layout } })
              open_diff("old", kinds[1])
              vim.cmd("tabnew")
              local during = {}
              lock.enter(function()
                open_diff("new", kinds[2])
                during.registered = vim.tbl_keys(diff._get_active_diffs())
              end)
              return during
            end

            it(
              "answers the old call and the new call once each, and keeps the old diff until windows can change",
              function()
                local during = replace_while_locked()

                assert.same({ "DIFF_REJECTED" }, answer_texts("old"))
                assert.same({ "error -32000" }, answer_texts("new"))
                assert.same({ tab_name }, during.registered, "the old diff waits for the gate")
              end
            )

            it("closes the old diff and leaves no command-line window and no plugin buffer", function()
              replace_while_locked()

              assert.is_true(
                vim.wait(2000, function()
                  return next(diff._get_active_diffs()) == nil
                end, 10),
                "the old diff closes once windows can change"
              )
              assert.same({}, command_line_windows(), "no window shows the command-line window")
              assert.same({}, buffers_of_the_plugin(), "no proposal buffer is left")
              assert.equal(#vim.api.nvim_list_tabpages(), #vim.api.nvim_list_wins(), "no window is left over")
            end)

            it("opens a later diff of the new call's kind under the same tab name", function()
              replace_while_locked()
              assert.is_true(
                vim.wait(2000, function()
                  return next(diff._get_active_diffs()) == nil
                end, 10),
                "the old diff closes once windows can change"
              )

              local later = open_diff("later", kinds[2])

              assert.is_true(later._deferred, "the later openDiff opens and waits for the user")
              assert.equal("pending", diff._get_active_diffs()[tab_name].status)
              diff.close_diff_by_tab_name(tab_name)
              assert.same({ "DIFF_REJECTED" }, answer_texts("later"), "the later call is answered once")
            end)
          end
        )
      end
    end
  end
end)

require("tests.busted_setup")

describe("Diff new-tab with hidden terminal", function()
  local open_diff_tool = require("claudecode.tools.open_diff")
  local diff = require("claudecode.diff")

  local test_old_file = "/tmp/claudecode_diff_hide_old.txt"
  local test_new_file = "/tmp/claudecode_diff_hide_new.txt"
  local test_tab_name = "hide-term-in-new-tab"

  before_each(function()
    -- Create a real file so filereadable() returns 1 in mocks
    local f = io.open(test_old_file, "w")
    f:write("line1\nline2\n")
    f:close()

    -- Ensure a clean diff state
    diff._cleanup_all_active_diffs("test_setup")

    -- Provide minimal config directly to diff module
    diff.setup({
      terminal = { split_side = "right", split_width_percentage = 0.30 },
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = true,
        keep_terminal_focus = false,
        hide_terminal_in_new_tab = true,
      },
    })

    -- Stub terminal provider with a valid terminal buffer (should be ignored due to hide flag)
    local term_buf = vim.api.nvim_create_buf(false, true)
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return term_buf
      end,
      ensure_visible = function() end,
    }
  end)

  after_each(function()
    os.remove(test_old_file)
    os.remove(test_new_file)
    -- Clear stub to avoid side effects
    package.loaded["claudecode.terminal"] = nil
    diff._cleanup_all_active_diffs("test_teardown")
  end)

  it("does not place a terminal split in the new tab when hidden", function()
    local params = {
      old_file_path = test_old_file,
      new_file_path = test_new_file,
      new_file_contents = "updated content\n",
      tab_name = test_tab_name,
    }

    local co = coroutine.create(function()
      open_diff_tool.handler(params)
    end)

    -- Start the tool (it will yield waiting for user action)
    local ok, err = coroutine.resume(co)
    assert.is_true(ok, tostring(err))
    assert.equal("suspended", coroutine.status(co))

    -- Inspect active diff metadata
    local active = diff._get_active_diffs()
    assert.is_table(active[test_tab_name])
    assert.is_true(active[test_tab_name].created_new_tab)
    -- Key assertion: no terminal window was created in the new tab
    assert.is_nil(active[test_tab_name].terminal_win_in_new_tab)

    -- Resolve to finish the coroutine
    vim.schedule(function()
      diff._resolve_diff_as_rejected(test_tab_name)
    end)
    vim.wait(100, function()
      return coroutine.status(co) == "dead"
    end)
  end)

  it("wipes the initial unnamed buffer created by tabnew", function()
    local params = {
      old_file_path = test_old_file,
      new_file_path = test_new_file,
      new_file_contents = "updated content\n",
      tab_name = test_tab_name,
    }

    -- Start handler
    local co = coroutine.create(function()
      open_diff_tool.handler(params)
    end)

    local ok, err = coroutine.resume(co)
    assert.is_true(ok, tostring(err))
    assert.equal("suspended", coroutine.status(co))

    -- After diff opens, the initial unnamed buffer in the new tab should be gone
    -- because plugin marks it bufhidden=wipe and then replaces it
    local unnamed_count = 0
    for _, buf in pairs(vim._buffers) do
      if buf.name == nil or buf.name == "" then
        unnamed_count = unnamed_count + 1
      end
    end
    -- There may be zero unnamed buffers, or other tests may create scratch buffers with names
    -- The important assertion is that there is no unnamed buffer with bufhidden=wipe lingering
    for id, buf in pairs(vim._buffers) do
      local bh = buf.options and buf.options.bufhidden or nil
      assert.not_equal("wipe", bh, "Found lingering unnamed buffer with bufhidden=wipe (buf " .. tostring(id) .. ")")
    end

    -- Cleanup by rejecting
    vim.schedule(function()
      diff._resolve_diff_as_rejected(test_tab_name)
    end)
    vim.wait(100, function()
      return coroutine.status(co) == "dead"
    end)
  end)
end)

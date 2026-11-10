require("tests.busted_setup")
local temp_dir = require("tests.helpers.temp_dir")

describe("Diff in a new tab: attaching the Claude terminal buffer", function()
  local open_diff_tool = require("claudecode.tools.open_diff")
  local diff = require("claudecode.diff")

  local dir, old_file, term_buf
  local attaches
  local real_set_buf

  local layouts = { "vertical", "unified" }

  local function ignores_bufenter(value)
    local ignored = false
    for entry in (value or ""):gmatch("[^,]+") do
      entry = entry:lower()
      if entry == "-bufenter" then
        return false
      elseif entry == "bufenter" or entry == "all" then
        ignored = true
      end
    end
    return ignored
  end

  local function open_diff(tab_name)
    local co = coroutine.create(function()
      open_diff_tool.handler({
        old_file_path = old_file,
        new_file_path = old_file,
        new_file_contents = "updated\n",
        tab_name = tab_name,
      })
    end)
    local ok, err = coroutine.resume(co)
    assert.is_true(ok, tostring(err))
    assert.equal("suspended", coroutine.status(co))
    return co
  end

  local function close_diff(tab_name, co)
    vim.schedule(function()
      diff._resolve_diff_as_rejected(tab_name)
    end)
    vim.wait(100, function()
      return coroutine.status(co) == "dead"
    end)
  end

  setup(function()
    dir = temp_dir.new()
    old_file = dir .. "/claudecode_new_tab_insert_old.txt"
  end)

  teardown(function()
    temp_dir.remove(dir)
  end)

  before_each(function()
    local f = assert(io.open(old_file, "w"))
    f:write("line1\nline2\n")
    f:close()

    diff._cleanup_all_active_diffs("test_setup")

    term_buf = vim.api.nvim_create_buf(false, true)
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return term_buf
      end,
      ensure_visible = function() end,
    }

    vim.o.eventignore = ""
    attaches = {}
    real_set_buf = vim.api.nvim_win_set_buf
    vim.api.nvim_win_set_buf = function(win, buf)
      if buf == term_buf then
        table.insert(attaches, { win = win, eventignore = vim.o.eventignore })
      end
      return real_set_buf(win, buf)
    end
  end)

  after_each(function()
    vim.api.nvim_win_set_buf = real_set_buf
    vim.o.eventignore = ""
    package.loaded["claudecode.terminal"] = nil
    diff._cleanup_all_active_diffs("test_teardown")
    os.remove(old_file)
  end)

  for _, layout in ipairs(layouts) do
    describe("with layout = " .. layout, function()
      before_each(function()
        diff.setup({
          terminal = { split_side = "right", split_width_percentage = 0.30 },
          diff_opts = {
            layout = layout,
            open_in_new_tab = true,
            keep_terminal_focus = false,
            hide_terminal_in_new_tab = false,
          },
        })
      end)

      it("ignores BufEnter while the terminal buffer goes into the new tab", function()
        local co = open_diff("new-tab-insert-" .. layout)

        assert.equal(1, #attaches, "the terminal buffer goes into one window of the new tab")
        assert.is_true(ignores_bufenter(attaches[1].eventignore), "BufEnter is ignored: " .. attaches[1].eventignore)

        close_diff("new-tab-insert-" .. layout, co)
      end)

      it("gives 'eventignore' back to the user's value", function()
        vim.o.eventignore = "CursorHold"
        local co = open_diff("new-tab-restore-" .. layout)

        assert.equal("CursorHold", vim.o.eventignore)

        close_diff("new-tab-restore-" .. layout, co)
      end)

      it("ignores BufEnter again for each further diff in a new tab", function()
        local first = open_diff("new-tab-first-" .. layout)
        local second = open_diff("new-tab-second-" .. layout)

        assert.equal(2, #attaches)
        assert.is_true(ignores_bufenter(attaches[2].eventignore), "BufEnter is ignored: " .. attaches[2].eventignore)

        close_diff("new-tab-second-" .. layout, second)
        close_diff("new-tab-first-" .. layout, first)
      end)
    end)
  end
end)

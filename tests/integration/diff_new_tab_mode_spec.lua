if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("a diff in a new tab: mode", function()
    pending("needs a real Neovim")
  end)
  return
end

local helper = require("tests.helpers.new_tab_diff_child")

describe("a diff in a new tab: mode", function()
  local child = helper.new()

  after_each(child.stop)

  local layouts = { "vertical", "unified" }

  for _, layout in ipairs(layouts) do
    describe("with layout = " .. layout, function()
      it("keeps a second diff in a new tab in Normal mode", function()
        child.start({ layout = layout })

        child.open_diff("a.txt", "first diff")
        local first = child.state()
        child.open_diff("b.txt", "second diff")
        local second = child.state()

        assert.equal(2, first.tabs)
        assert.is_true(helper.shows_proposal(first), first.name)
        assert.equal("n", first.mode)
        assert.equal(3, second.tabs)
        assert.is_true(helper.shows_proposal(second), second.name)
        assert.equal("n", second.mode)
      end)

      it("keeps a diff in Normal mode when the terminal buffer auto-inserts on BufEnter, as with Snacks", function()
        child.start({ layout = layout, snacks_auto_insert = true })

        child.open_diff("a.txt", "first diff")
        local first = child.state()
        child.open_diff("b.txt", "second diff")
        local second = child.state()

        assert.is_true(helper.shows_proposal(first), first.name)
        assert.equal("n", first.mode)
        assert.is_true(helper.shows_proposal(second), second.name)
        assert.equal("n", second.mode)
      end)

      it("still enters terminal mode when the user focuses the terminal in the new tab", function()
        child.start({ layout = layout, snacks_auto_insert = true })
        child.open_diff("a.txt", "first diff")
        child.open_diff("b.txt", "second diff")
        assert.equal("n", child.state().mode)

        child.focus_terminal_in_tab()
        local state = child.state()

        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)

      it("enters terminal mode on focusing the terminal in the new tab through the diff's own handler", function()
        child.start({ layout = layout })
        child.open_diff("a.txt", "first diff")
        assert.equal("n", child.state().mode)

        child.focus_terminal_in_tab()
        local state = child.state()

        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)

      it("stays in terminal-normal mode on focusing that terminal with terminal.auto_insert = false", function()
        child.start({ layout = layout, auto_insert = false })
        child.open_diff("a.txt", "first diff")

        child.focus_terminal_in_tab()
        local state = child.state()

        assert.equal("terminal", state.buftype)
        assert.equal("nt", state.mode)
      end)

      it("leaves the cursor in the terminal, in terminal mode, with keep_terminal_focus", function()
        child.start({ layout = layout, keep_terminal_focus = true })

        child.open_diff("a.txt", "first diff")
        vim.wait(1000, function()
          return child.mode() == "t"
        end, 50)
        local state = child.state()

        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)
    end)
  end
end)

if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("closing a diff in a new tab: mode", function()
    pending("needs a real Neovim")
  end)
  return
end

local helper = require("tests.helpers.new_tab_diff_child")

describe("closing a diff in a new tab: mode", function()
  local child = helper.new()

  after_each(child.stop)

  local layouts = { "vertical", "unified" }

  for _, layout in ipairs(layouts) do
    describe("with layout = " .. layout, function()
      describe("when Claude closes it", function()
        for _, snacks_auto_insert in ipairs({ false, true }) do
          local provider = snacks_auto_insert and " (the terminal buffer also auto-inserts on BufEnter, as with Snacks)"
            or ""

          it("leaves Normal mode in the file after the user left the diff tab's terminal" .. provider, function()
            child.start({ layout = layout, snacks_auto_insert = snacks_auto_insert })
            child.open_diff("a.txt", "first diff")
            child.focus_terminal_in_tab()
            assert.equal("t", child.state().mode)
            assert.equal("nt", child.leave_terminal_mode().mode)

            child.close_diff("first diff")
            local state = child.state()

            assert.equal(1, state.tabs)
            assert.is_true(state.name:find("a.txt", 1, true) ~= nil, state.name)
            assert.equal("n", state.mode)
          end)

          it("leaves Normal mode in the file when the user is in the first tab" .. provider, function()
            child.start({ layout = layout, snacks_auto_insert = snacks_auto_insert })
            child.open_diff("a.txt", "first diff")
            child.focus_terminal_in_tab()
            child.leave_terminal_mode()
            local before = child.go_to_first_tab()
            assert.equal("n", before.mode)
            assert.is_true(before.name:find("a.txt", 1, true) ~= nil, before.name)

            child.close_diff("first diff")
            local state = child.state()

            assert.equal(1, state.tabs)
            assert.is_true(state.name:find("a.txt", 1, true) ~= nil, state.name)
            assert.equal("n", state.mode)
          end)
        end

        it("leaves Normal mode in the file when the user was still in terminal mode", function()
          child.start({ layout = layout })
          child.open_diff("a.txt", "first diff")
          child.focus_terminal_in_tab()
          assert.equal("t", child.state().mode)

          child.close_diff("first diff")
          local state = child.state()

          assert.equal(1, state.tabs)
          assert.is_true(state.name:find("a.txt", 1, true) ~= nil, state.name)
          assert.equal("n", state.mode)
        end)
      end)
    end)
  end
end)

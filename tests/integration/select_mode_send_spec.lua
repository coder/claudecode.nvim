-- Real-Neovim check that README.md's `mode = "v"` `<cmd>ClaudeCodeSend<cr>` mapping (a :vmap) leaves Select mode.
-- Neovim runs a :vmap from Select mode in Visual mode and queues a key that restores Select mode after it. Busted's
-- mock vim has no typeahead, so there it is pending; scripts/run_integration_tests_individually.sh runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("<cmd>ClaudeCodeSend<cr> :vmap", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("<cmd>ClaudeCodeSend<cr> :vmap", function()
  local selection = require("claudecode.selection")
  local real_send, sent

  before_each(function()
    require("claudecode")._create_commands()
    real_send = selection.send_at_mention_for_visual_selection
    sent = {}
    selection.send_at_mention_for_visual_selection = function(line1, line2)
      table.insert(sent, { line1, line2 })
      return true
    end
    vim.keymap.set("v", "<F6>", "<cmd>ClaudeCodeSend<cr>")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end)

  after_each(function()
    selection.send_at_mention_for_visual_selection = real_send
    vim.keymap.del("v", "<F6>")
    vim.cmd([[silent! execute "normal! \<Esc>"]])
  end)

  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
    vim.wait(1000, function()
      return #sent > 0
    end)
  end

  for _, case in ipairs({
    { name = "Visual mode", keys = "vj" },
    { name = "charwise Select mode", keys = "vj<C-g>" },
    { name = "linewise Select mode", keys = "Vj<C-g>" },
    { name = "blockwise Select mode", keys = "<C-v>j<C-g>" },
  }) do
    it("sends the selected lines and returns to Normal mode from " .. case.name, function()
      press(case.keys .. "<F6>")

      assert.are.same({ { 1, 2 } }, sent)
      assert.are.equal("n", vim.api.nvim_get_mode().mode)
    end)
  end

  it("does not run the user's Normal-mode gV mapping", function()
    local ran
    vim.keymap.set("n", "gV", function()
      ran = true
    end)

    press("vj<C-g><F6>")
    vim.keymap.del("n", "gV")

    assert.are.same({ { 1, 2 } }, sent)
    assert.is_nil(ran)
  end)
end)

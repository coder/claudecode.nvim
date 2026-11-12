if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("what the Claude terminal placement keeps of a pending diff's answer", function()
    pending("needs a real Neovim")
  end)
  return
end

-- A pending `openDiff` has a proposal buffer. When the terminal is put into a split of the proposal's window, a
-- `BufLeave` autocmd of the user's on the proposal runs, and what it does to the windows decides whether the proposal
-- is hidden, and so whether the diff gets its answer (#238). The cases go through the public commands, so they pass on a
-- tree that has no placement helper, and the helper must keep them. Each case runs in its own headless Neovim.
local child = require("tests.helpers.placement_child")

describe("what the Claude terminal placement keeps of a pending diff's answer", function()
  local SCENARIO = [==[
-- A pending openDiff whose proposal is the buffer that the terminal's split shows. A BufLeave autocmd of the user's on
-- the proposal (P.kind), then the terminal is shown: focused (:ClaudeCodeOpen, P.focus "f") or not (ensure_visible,
-- "u"). Does Claude get an answer, and is the proposal still in a window?
local terminal = setup_native()
local tools = require("claudecode.tools.init")
local diff = require("claudecode.diff")
tools.register_all()
_G.claude_deferred_responses = {}
vim.fn.writefile({ "other" }, dir .. "/other.txt")
local answers = {}
vim.defer_fn(function()
  terminal.open()
  vim.defer_fn(function()
    hide_terminal(terminal)
    vim.cmd("stopinsert")
    local call = tools.handle_invoke({ id = "c" }, {
      name = "openDiff",
      arguments = {
        old_file_path = dir .. "/a.txt",
        new_file_path = dir .. "/a.txt",
        new_file_contents = "alpha changed\n",
        tab_name = "handler proposal",
      },
    })
    _G.claude_deferred_responses[tostring(call.coroutine)] = function(response)
      answers[#answers + 1] = response.content and response.content[1].text or "?"
    end
    local proposal = diff._get_active_diffs()["handler proposal"].new_buffer
    local proposal_window = vim.fn.win_findbuf(proposal)[1]
    vim.api.nvim_set_current_win(proposal_window)
    local kind = P.kind
    vim.api.nvim_create_autocmd("BufLeave", {
      buffer = proposal,
      once = true,
      nested = P.nested == true,
      callback = function()
        local current = vim.api.nvim_get_current_win()
        if kind == "close_current" then
          pcall(vim.api.nvim_win_close, current, true)
        elseif kind == "close_command" then
          pcall(vim.cmd, "close")
        elseif kind == "hide_command" then
          pcall(vim.cmd, "hide")
        elseif kind == "enew" then
          pcall(vim.cmd, "enew")
        elseif kind == "edit_other" then
          pcall(vim.cmd, "edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
        elseif kind == "buffer_file" then
          pcall(vim.cmd, "buffer " .. file)
        elseif kind == "previous_window" then
          pcall(vim.cmd, "wincmd p")
        end
      end,
    })
    result.show_ok = pcall(function()
      if P.focus == "f" then
        terminal.open()
      else
        terminal.ensure_visible()
      end
    end)
    vim.defer_fn(function()
      local entry = diff._get_active_diffs()["handler proposal"]
      local valid = vim.api.nvim_buf_is_valid(proposal)
      result.answers = #answers
      result.status = entry and entry.status or "cleared"
      result.proposal_windows = valid and #vim.fn.win_findbuf(proposal) or -1
      result.outcome = #answers > 0 and "answered" or (result.proposal_windows > 0 and "pending-visible" or "pending-hidden")
      finish()
    end, 400)
  end, 200)
end, 20)
]==]

  describe("a BufLeave autocmd of the user's on the proposal", function()
    -- The proposal is in the user's window and in the split that the terminal is shown in. The autocmds that act on
    -- the current window act on the split, which holds a second window of the proposal.
    local keeps = { "noop", "enew", "edit_other", "buffer_file", "previous_window" }
    local closes = { "close_current", "close_command", "hide_command" }
    for _, focus in ipairs({ "f", "u" }) do
      for _, kind in ipairs(keeps) do
        it("leaves the proposal on screen and the diff pending: " .. kind .. ", focus " .. focus, function()
          local result = child.run_to_end(SCENARIO, { kind = kind, focus = focus })

          assert.is_true(result.show_ok)
          assert.equal("pending-visible", result.outcome, vim.inspect(result))
          assert.equal(0, result.answers)
        end)
      end
      for _, kind in ipairs(closes) do
        it("never leaves the proposal in no window with the diff pending: " .. kind .. ", focus " .. focus, function()
          local result = child.run_to_end(SCENARIO, { kind = kind, focus = focus })

          assert.is_not.equal("pending-hidden", result.outcome, vim.inspect(result))
        end)
      end
    end
  end)
end)

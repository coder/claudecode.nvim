-- States in which Neovim refuses window changes, for the real-Neovim specs: the command-line window (E11) and textlock
-- (E565). A headless Neovim has no keyboard, so each state starts from nvim_feedkeys in "x" mode and runs the function
-- inside it: in a CmdwinEnter handler for the command-line window, in an <expr> mapping for textlock. Each function
-- raises what `fn` raised once Neovim is out of the state again.
local M = {}

local function keys(text)
  return vim.api.nvim_replace_termcodes(text, true, false, true)
end

local function run_refused(fn)
  assert(not pcall(vim.api.nvim_set_current_win, vim.api.nvim_get_current_win()), "Neovim refuses window changes here")
  fn()
end

function M.in_command_line_window(fn)
  local failure
  vim.api.nvim_create_autocmd("CmdwinEnter", {
    once = true,
    callback = function()
      local ok, err = pcall(run_refused, fn)
      failure = not ok and err or nil
    end,
  })
  vim.api.nvim_feedkeys(keys("q:"), "x", false)
  assert(not failure, failure)
end

function M.in_textlock(fn)
  local failure
  local mapping = "<Plug>(claudecode-test-textlock)"
  vim.keymap.set("n", mapping, function()
    local ok, err = pcall(run_refused, fn)
    failure = not ok and err or nil
    return ""
  end, { expr = true })
  vim.api.nvim_feedkeys(keys(mapping), "x", false)
  vim.keymap.del("n", mapping)
  assert(not failure, failure)
end

M.states = {
  { name = "the command-line window is open", enter = M.in_command_line_window },
  { name = "text is locked", enter = M.in_textlock },
}

return M

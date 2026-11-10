-- Real-Neovim check that openFile sends Claude only the selection it makes, through the plugin's own tracker.
-- It needs real autocommands, so under busted's mock vim it is pending; scripts/run_integration_tests_individually.sh
-- runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openFile with selection tracking", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openFile with selection tracking", function()
  local selection = require("claudecode.selection")
  local open_file = require("claudecode.tools.open_file")
  local sent

  before_each(function()
    sent = {}
    selection.enable({
      broadcast = function(event, params)
        table.insert(sent, { event = event, text = params.text })
      end,
    }, 50)
  end)

  after_each(function()
    selection.disable()
    vim.cmd([[silent! execute "normal! \<Esc>"]])
  end)

  it("sends no selection_changed while it builds the selection", function()
    local path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "one", "two", "three", "four" }, path)
    local mode_changes = {}
    local group = vim.api.nvim_create_augroup("OpenFileSelectionSpec", { clear = true })
    vim.api.nvim_create_autocmd("ModeChanged", {
      group = group,
      callback = function()
        table.insert(mode_changes, vim.v.event.old_mode .. ">" .. vim.v.event.new_mode)
      end,
    })

    open_file.handler({ filePath = path, startText = "two", endText = "three" })
    vim.api.nvim_del_augroup_by_id(group)

    assert.are.same({}, sent)
    assert.are.same({ "n>v" }, mode_changes)
    assert.are.same("v", vim.api.nvim_get_mode().mode)
  end)

  it("selects in the preview window with preview = true", function()
    local main_path = vim.fn.tempname() .. ".txt"
    local preview_path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "one", "two", "three", "four" }, main_path)
    vim.fn.writefile({ "alpha", "beta", "gamma", "delta" }, preview_path)
    vim.cmd("edit " .. vim.fn.fnameescape(main_path))

    local result = open_file.handler({ filePath = preview_path, preview = true, startLine = 2, endLine = 3 })
    local mode = vim.api.nvim_get_mode().mode
    local in_preview_window = vim.wo.previewwindow
    vim.cmd('normal! "zy')
    vim.cmd("pclose")

    assert.are.same("Opened file and selected lines 2 to 3", result.content[1].text)
    assert.are.same("v", mode)
    assert.is_true(in_preview_window)
    assert.are.same("beta\ngamma", vim.fn.getreg("z"))
  end)
end)

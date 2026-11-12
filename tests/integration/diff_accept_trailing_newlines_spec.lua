if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the text a proposed diff accepts", function()
    pending("needs a real Neovim")
  end)
  return
end

-- The accepted text goes back to Claude as the file's new contents, so it must match the proposal byte for byte.
-- A proposal that ends in blank lines lost one of them in the unified layout.
describe("the text a proposed diff accepts", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local tab = "✻ [Claude Code] trailing.txt ⧉"
  local dir, answers

  local function open_diff(layout, old_text, new_text)
    local file = dir .. "/trailing.txt"
    local handle = assert(io.open(file, "wb"))
    handle:write(old_text)
    handle:close()
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    diff.setup({ terminal = { provider = "none" }, diff_opts = { layout = layout } })
    local call = tools.handle_invoke({ id = "trailing_spec" }, {
      name = "openDiff",
      arguments = { old_file_path = file, new_file_path = file, new_file_contents = new_text, tab_name = tab },
    })
    assert.is_true(call._deferred, "openDiff waits for the user")
    _G.claude_deferred_responses[tostring(call.coroutine)] = function(response)
      answers[#answers + 1] = response
    end
    return diff._get_active_diffs()[tab]
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

  local layouts = { "vertical" }
  if vim.fn.has("nvim-0.9") == 1 then
    layouts[#layouts + 1] = "unified"
  else
    describe("in the unified layout", function()
      pending("the unified layout needs Neovim 0.9")
    end)
  end

  -- Each proposal ends in the shape under test. Each one runs against a file with other text, so the diff has hunks,
  -- and against a file that is one line shorter, so the diff is a pure insertion.
  local proposals = {
    { name = "one blank line after the last line", text = "a\n\n" },
    { name = "two blank lines after the last line", text = "a\n\n\n" },
    { name = "a final line without a line break", text = "a" },
    { name = "a single final line break", text = "a\n" },
    { name = "a blank line only", text = "\n" },
    { name = "two blank lines only", text = "\n\n" },
    { name = "a blank line inside and one after the last line", text = "a\n\nb\n\n" },
  }
  local old_files = {
    { name = "a file with other text", text = "old\n" },
    { name = "a file that is a line shorter", text = "a\n" },
  }

  for _, layout in ipairs(layouts) do
    describe("in the " .. layout .. " layout", function()
      for _, old_file in ipairs(old_files) do
        for _, proposal in ipairs(proposals) do
          -- The vertical layout writes a final line break after a proposal that has none. That is not what the
          -- unified fix changes, so this case stays pending there.
          local case = it
          if layout == "vertical" and proposal.text:sub(-1) ~= "\n" then
            case = pending
          end
          case(("keeps %s of a proposal against %s"):format(proposal.name, old_file.name), function()
            local state = open_diff(layout, old_file.text, proposal.text)

            vim.api.nvim_set_current_win(state.new_window)
            vim.cmd("write")

            assert.equal(1, #answers, "one answer")
            assert.equal("FILE_SAVED", answers[1].content[1].text)
            assert.equal(vim.inspect(proposal.text), vim.inspect(answers[1].content[2].text))
          end)
        end
      end
    end)
  end
end)

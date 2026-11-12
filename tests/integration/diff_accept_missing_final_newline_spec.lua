if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the text a proposed diff accepts, by how the proposal ends", function()
    pending("needs a real Neovim")
  end)
  return
end

-- The accepted text goes back to Claude as the file's new contents, so it must match the proposal byte for byte. The
-- vertical and horizontal layouts take that text from the proposal buffer. A new buffer has 'eol' on, so a proposal
-- without a final line break was accepted with one: "a" came back as "a\n".
describe("the text a proposed diff accepts, by how the proposal ends", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local tab = "✻ [Claude Code] ending.txt ⧉"
  local dir, answers

  --- Opens the diff of a proposal. `old_text` nil means the file does not exist yet.
  local function open_diff(layout, old_text, new_text)
    local file = dir .. "/ending.txt"
    if old_text then
      local handle = assert(io.open(file, "wb"))
      handle:write(old_text)
      handle:close()
      vim.cmd("edit " .. vim.fn.fnameescape(file))
    end
    diff.setup({ terminal = { provider = "none" }, diff_opts = { layout = layout } })
    local call = tools.handle_invoke({ id = "ending_spec" }, {
      name = "openDiff",
      arguments = { old_file_path = file, new_file_path = file, new_file_contents = new_text, tab_name = tab },
    })
    assert.is_true(call._deferred, "openDiff waits for the user")
    _G.claude_deferred_responses[tostring(call.coroutine)] = function(response)
      answers[#answers + 1] = response
    end
    return diff._get_active_diffs()[tab]
  end

  local function accept(state)
    vim.api.nvim_set_current_win(state.new_window)
    vim.cmd("write")
    assert.equals(1, #answers, "one answer")
    assert.equals("FILE_SAVED", answers[1].content[1].text)
    return answers[1].content[2].text
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

  local split_layouts = { "vertical", "horizontal" }
  local all_layouts = { "vertical", "horizontal", "unified" }

  local proposals = {
    { name = "a final line without a line break", text = "a" },
    { name = "two lines and no final line break", text = "a\nb" },
    { name = "no text", text = "" },
    { name = "a blank line inside and no final line break", text = "a\n\nb" },
    { name = "one final line break", text = "a\n" },
    { name = "two lines and a final line break", text = "a\nb\n" },
    { name = "a blank line only", text = "\n" },
    { name = "one blank line after the last line", text = "a\n\n" },
    { name = "two blank lines after the last line", text = "a\n\n\n" },
    { name = "two blank lines only", text = "\n\n" },
  }
  local old_files = {
    { name = "a file with other text", text = "old\n" },
    { name = "a file without a final line break", text = "old" },
    { name = "a file that does not exist yet", text = nil },
  }

  for _, layout in ipairs(all_layouts) do
    describe("in the " .. layout .. " layout", function()
      for _, old_file in ipairs(old_files) do
        for _, proposal in ipairs(proposals) do
          it(("accepts %s as it is, against %s"):format(proposal.name, old_file.name), function()
            local state = open_diff(layout, old_file.text, proposal.text)

            assert.equal(vim.inspect(proposal.text), vim.inspect(accept(state)))
          end)
        end
      end
    end)
  end

  -- The text comes from the buffer, so the user's own edits reach Claude, and the buffer keeps the ending of the proposal.
  for _, layout in ipairs(split_layouts) do
    describe("in the " .. layout .. " layout, after the user edits the proposal", function()
      local function append_line(state)
        local buffer = vim.api.nvim_win_get_buf(state.new_window)
        vim.api.nvim_buf_set_lines(buffer, -1, -1, false, { "b" })
      end

      it("adds the edit to a proposal without a final line break and adds no line break", function()
        local state = open_diff(layout, "old\n", "a")

        append_line(state)

        assert.equal(vim.inspect("a\nb"), vim.inspect(accept(state)))
      end)

      it("adds the edit to a proposal with a final line break and keeps it", function()
        local state = open_diff(layout, "old\n", "a\n")

        append_line(state)

        assert.equal(vim.inspect("a\nb\n"), vim.inspect(accept(state)))
      end)
    end)
  end
end)

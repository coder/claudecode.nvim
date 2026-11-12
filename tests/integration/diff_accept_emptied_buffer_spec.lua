if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the text a diff accepts after the user empties the proposal", function()
    pending("needs a real Neovim")
  end)
  return
end

-- A user who empties the proposal buffer (`ggdG`) and saves it with `:w` accepts an empty file. Neovim's own `:w` of an
-- emptied buffer writes no bytes, whatever 'eol' says. The split layouts answered "\n" for it, because the saved text
-- ends with a line break whenever 'eol' is on and `nvim_buf_get_lines` returns one empty string for a buffer with no
-- lines at all.
describe("the text a diff accepts after the user empties the proposal", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local tab = "✻ [Claude Code] emptied.txt ⧉"
  local dir, answers

  --- Opens the diff of a proposal against a file that holds "old\n".
  local function open_diff(layout, new_text)
    local file = dir .. "/emptied.txt"
    local handle = assert(io.open(file, "wb"))
    handle:write("old\n")
    handle:close()
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    diff.setup({ terminal = { provider = "none" }, diff_opts = { layout = layout } })
    local call = tools.handle_invoke({ id = "emptied_spec" }, {
      name = "openDiff",
      arguments = { old_file_path = file, new_file_path = file, new_file_contents = new_text, tab_name = tab },
    })
    assert.is_true(call._deferred, "openDiff waits for the user")
    _G.claude_deferred_responses[tostring(call.coroutine)] = function(response)
      answers[#answers + 1] = response
    end
    return diff._get_active_diffs()[tab]
  end

  --- What Neovim's own `:w` writes for a file buffer that holds `text` after the same commands.
  local function neovim_writes(text, commands)
    local file = dir .. "/oracle.txt"
    local handle = assert(io.open(file, "wb"))
    handle:write(text)
    handle:close()
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    for _, command in ipairs(commands) do
      vim.cmd(command)
    end
    vim.cmd("write")
    local written = assert(io.open(file, "rb"))
    local bytes = written:read("*a")
    written:close()
    vim.cmd("bwipeout!")
    return bytes
  end

  --- Runs `commands` in the proposal window, then saves with `:write`, and returns the text that Claude gets.
  local function edit_and_accept(state, commands)
    vim.api.nvim_set_current_win(state.new_window)
    for _, command in ipairs(commands) do
      pcall(vim.cmd, command) -- the unified proposal is read-only, so its edits can fail
    end
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

  local proposals = {
    { name = "two lines and a final line break", text = "a\nb\n" },
    { name = "one line and a final line break", text = "a\n" },
    { name = "a blank line only", text = "\n" },
    { name = "a final line without a line break", text = "a" },
    { name = "two lines and no final line break", text = "a\nb" },
    { name = "no text", text = "" },
  }
  local emptyings = {
    { name = "ggdG", commands = { "normal! ggdG" } },
    { name = ":%delete", commands = { "%delete _" } },
  }

  for _, layout in ipairs(split_layouts) do
    describe("in the " .. layout .. " layout", function()
      for _, proposal in ipairs(proposals) do
        for _, emptying in ipairs(emptyings) do
          it(
            ("accepts what :w writes for a buffer emptied with %s, from %s"):format(emptying.name, proposal.name),
            function()
              local expected = neovim_writes(proposal.text, emptying.commands)
              assert.equal("", expected, "Neovim writes no bytes for an emptied buffer")
              local state = open_diff(layout, proposal.text)

              assert.equal(vim.inspect(expected), vim.inspect(edit_and_accept(state, emptying.commands)))
            end
          )
        end
      end

      -- Controls: these gave the right text before, and the same text as :w.
      local controls = {
        { name = "a blank line left in the buffer", text = "\n", commands = {} },
        { name = "no edit at all", text = "a\nb\n", commands = {} },
        { name = "an empty proposal without an edit", text = "", commands = {} },
        { name = "one line deleted", text = "a\nb\n", commands = { "normal! ggdd" } },
        { name = "text typed into the emptied buffer", text = "a\nb\n", commands = { "normal! ggdG", "normal! ix" } },
      }
      for _, control in ipairs(controls) do
        it("still accepts what :w writes after " .. control.name, function()
          local expected = neovim_writes(control.text, control.commands)
          local state = open_diff(layout, control.text)

          assert.equal(vim.inspect(expected), vim.inspect(edit_and_accept(state, control.commands)))
        end)
      end
    end)
  end

  -- The unified layout answers with the proposal, not with the buffer, so what the user does to the buffer does not
  -- reach Claude. This is a control: the answer is the proposal.
  describe("in the unified layout", function()
    for _, proposal in ipairs(proposals) do
      it("accepts the proposal, not the emptied buffer, from " .. proposal.name, function()
        local state = open_diff("unified", proposal.text)

        assert.equal(vim.inspect(proposal.text), vim.inspect(edit_and_accept(state, { "normal! ggdG" })))
      end)
    end
  end)
end)

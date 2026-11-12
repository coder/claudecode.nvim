if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the text a diff accepts when the proposal has CRLF line breaks", function()
    pending("needs a real Neovim")
  end)
  return
end

-- The accepted text goes back to Claude as the file's new contents, so it must be what Neovim's own `:w` writes for the
-- proposal. A proposal whose line breaks are all CRLF reads as 'fileformat' dos when Neovim reads it from a file, and
-- `:w` then ends every line with CRLF, a line that the user typed too. The split layouts kept each CR inside its line
-- and joined the lines with LF, so a line that the user typed, or the join of two lines, came back with an LF or with
-- a stray CR in the middle of a line. The unified layout's buffer is read-only, so its answer is the proposal itself.
describe("the text a diff accepts when the proposal has CRLF line breaks", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local tab = "✻ [Claude Code] crlf.txt ⧉"
  local dir, answers

  --- Opens the diff of a proposal. `old_text` nil means the file does not exist yet.
  local function open_diff(layout, old_text, new_text)
    local file = dir .. "/crlf.txt"
    if old_text then
      local handle = assert(io.open(file, "wb"))
      handle:write(old_text)
      handle:close()
      vim.cmd("edit " .. vim.fn.fnameescape(file))
    end
    diff.setup({ terminal = { provider = "none" }, diff_opts = { layout = layout } })
    local call = tools.handle_invoke({ id = "crlf_spec" }, {
      name = "openDiff",
      arguments = { old_file_path = file, new_file_path = file, new_file_contents = new_text, tab_name = tab },
    })
    assert.is_true(call._deferred, "openDiff waits for the user")
    _G.claude_deferred_responses[tostring(call.coroutine)] = function(response)
      answers[#answers + 1] = response
    end
    return diff._get_active_diffs()[tab]
  end

  --- What Neovim's own `:w` writes for the file `text` after the same commands. Neovim reads the text as a file, so it
  --- detects 'fileformat' as it does for any file.
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
      vim.cmd(command)
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
  local all_layouts = { "vertical", "horizontal" }
  if vim.fn.has("nvim-0.9") == 1 then
    all_layouts[#all_layouts + 1] = "unified"
  else
    describe("in the unified layout", function()
      pending("the unified layout needs Neovim 0.9")
    end)
  end

  -- A proposal without a final line break stays without one (#542), where a default `:w` adds one. `nofixeol` makes
  -- Neovim's `:w` keep it too, so the rest of the bytes can be compared.
  local proposals = {
    { name = "CRLF line breaks and a final one", text = "a\r\nb\r\n", commands = {} },
    { name = "a blank line inside", text = "a\r\n\r\nb\r\n", commands = {} },
    { name = "CRLF line breaks and no final one", text = "a\r\nb", commands = { "setlocal nofixeol" } },
  }
  local old_files = {
    { name = "a CRLF file", text = "old\r\n" },
    { name = "a file that does not exist yet", text = nil },
  }

  -- The edits change what the buffer holds, so the split layouts take the text from the buffer. The unified layout's
  -- buffer is read-only.
  local edits = {
    { name = "a typed line after the last line", commands = { "normal! Gox" } },
    { name = "a typed line above the first line", commands = { "normal! ggOx" } },
    { name = "all text replaced by a typed line", commands = { "normal! ggdG", "normal! ix" } },
    { name = "the first two lines joined", commands = { "normal! ggJ" } },
    { name = "the first line deleted", commands = { "normal! ggdd" } },
    { name = "a line break typed at the end of the first line", commands = { 'execute "normal! ggA\\<CR>x"' } },
  }

  for _, layout in ipairs(split_layouts) do
    describe("in the " .. layout .. " layout", function()
      for _, proposal in ipairs(proposals) do
        for _, edit in ipairs(edits) do
          local commands = vim.list_extend(vim.list_slice(proposal.commands), edit.commands)
          it(("accepts what :w writes after %s, from a proposal with %s"):format(edit.name, proposal.name), function()
            local expected = neovim_writes(proposal.text, commands)
            local state = open_diff(layout, "old\r\n", proposal.text)

            assert.equal(vim.inspect(expected), vim.inspect(edit_and_accept(state, commands)))
          end)
        end
      end

      for _, old_file in ipairs(old_files) do
        it("accepts what :w writes after a typed line, against " .. old_file.name, function()
          local commands = { "normal! Gox" }
          local expected = neovim_writes("a\r\nb\r\n", commands)
          local state = open_diff(layout, old_file.text, "a\r\nb\r\n")

          assert.equal(vim.inspect(expected), vim.inspect(edit_and_accept(state, commands)))
        end)
      end

      it("ends a line that the user types with CRLF", function()
        local state = open_diff(layout, "old\r\n", "a\r\nb\r\n")

        assert.equal(vim.inspect("a\r\nb\r\nx\r\n"), vim.inspect(edit_and_accept(state, { "normal! Gox" })))
      end)

      it("shows a CRLF proposal as 'fileformat' dos, without a CR in its lines", function()
        local state = open_diff(layout, "old\r\n", "a\r\nb\r\n")
        local buffer = vim.api.nvim_win_get_buf(state.new_window)

        assert.equal("dos", vim.api.nvim_buf_get_option(buffer, "fileformat"))
        assert.same({ "a", "b" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
      end)

      it("shows no difference between a CRLF proposal and the CRLF file that holds the same text", function()
        local state = open_diff(layout, "a\r\nb\r\nc\r\n", "a\r\nb\r\nc\r\n")

        local changed_lines = vim.api.nvim_win_call(state.new_window, function()
          local lines = {}
          for line = 1, vim.api.nvim_buf_line_count(0) do
            if vim.fn.diff_hlID(line, 1) ~= 0 then
              lines[#lines + 1] = line
            end
          end
          return lines
        end)

        assert.same({}, changed_lines)
      end)

      -- Controls: these gave the text that :w writes before the fix too. A proposal that is not all CRLF reads as unix, so
      -- it keeps the text it has, CRs included.
      local controls = {
        { name = "an LF proposal", text = "a\nb\n", commands = { "normal! Gox" }, format = "unix" },
        {
          name = "a proposal with CRLF and LF line breaks",
          text = "a\r\nb\n",
          commands = { "normal! Gox" },
          format = "unix",
        },
        { name = "a proposal with a lone CR", text = "a\rb\n", commands = { "normal! Gox" }, format = "unix" },
        { name = "a proposal with no line break", text = "a\r", commands = { "setlocal nofixeol" }, format = "unix" },
        { name = "a CRLF proposal that is not edited", text = "a\r\nb\r\n", commands = {} },
        { name = "an emptied CRLF proposal", text = "a\r\nb\r\n", commands = { "normal! ggdG" } },
      }
      for _, control in ipairs(controls) do
        it("still accepts what :w writes for " .. control.name, function()
          local expected = neovim_writes(control.text, control.commands)
          local state = open_diff(layout, "old\n", control.text)
          local buffer = vim.api.nvim_win_get_buf(state.new_window)

          if control.format then
            assert.equal(control.format, vim.api.nvim_buf_get_option(buffer, "fileformat"))
          end
          assert.equal(vim.inspect(expected), vim.inspect(edit_and_accept(state, control.commands)))
        end)
      end

      -- The user can change 'fileformat' of the proposal, and `:w` then writes that format.
      local formats = { "dos", "mac", "unix" }
      for _, format in ipairs(formats) do
        it("accepts what :w writes after :setlocal fileformat=" .. format .. " on an LF proposal", function()
          local commands = { "setlocal fileformat=" .. format }
          local expected = neovim_writes("a\nb\n", commands)
          local state = open_diff(layout, "old\n", "a\nb\n")

          assert.equal(vim.inspect(expected), vim.inspect(edit_and_accept(state, commands)))
        end)
      end
    end)
  end

  -- Every layout accepts an unedited proposal as it is. The unified layout has no other way: its buffer is read-only.
  for _, layout in ipairs(all_layouts) do
    for _, old_file in ipairs(old_files) do
      for _, proposal in ipairs(proposals) do
        it(
          ("the %s layout accepts a proposal with %s unedited, against %s"):format(layout, proposal.name, old_file.name),
          function()
            local state = open_diff(layout, old_file.text, proposal.text)

            assert.equal(vim.inspect(proposal.text), vim.inspect(edit_and_accept(state, {})))
          end
        )
      end
    end
  end
end)

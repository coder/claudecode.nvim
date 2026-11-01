-- Real-Neovim checks of :ClaudeCodeCloseAllDiffs finishing an accepted diff whose Claude client exited: the accepted
-- text goes into the file's buffer, and the user's :w writes it. Neovim's own file format, encoding, and write rules
-- decide the bytes, so under busted's mock vim this is pending; scripts/run_integration_tests_individually.sh runs it
-- in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe(":ClaudeCodeCloseAllDiffs hand-over", function()
    pending("needs a real Neovim")
  end)
  return
end

describe(":ClaudeCodeCloseAllDiffs hand-over", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local owner = { id = "hand_over_spec_client" }
  local dir, notes, real_notify, real_bufload

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    tools.register_all()
    require("claudecode")._create_commands()
    _G.claude_deferred_responses = {}
    notes = {}
    real_bufload = vim.fn.bufload
    real_notify = vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
  end)

  after_each(function()
    vim.notify = real_notify
    vim.fn.bufload = real_bufload
    diff.setup(nil)
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  local function write_bytes(path, bytes)
    local file = assert(io.open(path, "wb"))
    file:write(bytes)
    file:close()
  end

  local function read_bytes(path)
    local file = io.open(path, "rb")
    if not file then
      return nil
    end
    local bytes = file:read("*a")
    file:close()
    return bytes
  end

  -- Claude proposes `contents`, the user accepts with :w in the proposal, and the Claude client exits before it
  -- writes the file. `before_write` runs in the proposal buffer before the :w.
  local function accept_then_client_exits(path, contents, before_write)
    local tab = "✻ [Claude Code] " .. vim.fn.fnamemodify(path, ":t") .. " ⧉"
    local call = tools.handle_invoke(owner, {
      name = "openDiff",
      arguments = { old_file_path = path, new_file_path = path, new_file_contents = contents, tab_name = tab },
    })
    assert.is_true(call._deferred, "openDiff waits for the user")
    local answers = {}
    _G.claude_deferred_responses[tostring(call.coroutine)] = function(response)
      answers[#answers + 1] = response
    end
    vim.api.nvim_buf_call(diff._get_active_diffs()[tab].new_buffer, function()
      if before_write then
        before_write()
      end
      vim.cmd("write")
    end)
    assert.equal("FILE_SAVED", answers[1].content[1].text)
    diff.close_diffs_for_client(owner.id, "client disconnected")
    assert.equal("saved", diff._get_active_diffs()[tab].status)
    return tab
  end

  local function close_all_then_write(path)
    vim.cmd("ClaudeCodeCloseAllDiffs")
    local buf = vim.fn.bufnr(path)
    assert.are_not.equal(-1, buf, "the file's buffer holds the accepted text")
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    return buf
  end

  it("writes one CR per line break of a CRLF proposal to a dos file", function()
    local path = dir .. "/crlf.txt"
    write_bytes(path, "alpha\r\nbeta\r\n")
    vim.cmd.edit(path)
    assert.equal("dos", vim.bo.fileformat)
    accept_then_client_exits(path, "alpha\r\nBETA accepted\r\n")

    close_all_then_write(path)

    assert.equal("alpha\r\nBETA accepted\r\n", read_bytes(path))
  end)

  it("writes one CR per line break to a dos file when the proposal mixes CRLF and LF breaks", function()
    local path = dir .. "/mixed.txt"
    write_bytes(path, "alpha\r\nbeta\r\n")
    vim.cmd.edit(path)
    assert.equal("dos", vim.bo.fileformat)
    accept_then_client_exits(path, "alpha\r\nBETA accepted\ngamma\r\n")

    close_all_then_write(path)

    assert.equal("alpha\r\nBETA accepted\r\ngamma\r\n", read_bytes(path))
  end)

  it("names :checktime before :w! when the file's buffer is read-only", function()
    local path = dir .. "/readonly.txt"
    write_bytes(path, "alpha\n")
    vim.fn.setfperm(path, "r--r--r--")
    vim.cmd.edit(path)
    assert.is_true(vim.bo.readonly)
    accept_then_client_exits(path, "alpha accepted\n")

    vim.cmd("ClaudeCodeCloseAllDiffs")

    assert.is_truthy(notes[#notes]:find(": :checktime, then :w! writes them", 1, true), notes[#notes])
    vim.api.nvim_buf_call(vim.fn.bufnr(path), function()
      vim.cmd("silent write!")
    end)
    assert.equal("alpha accepted\n", read_bytes(path))
  end)

  it("writes CRLF line breaks to a dos file when the proposal has only LF breaks", function()
    local path = dir .. "/lf.txt"
    write_bytes(path, "alpha\r\nbeta\r\n")
    vim.cmd.edit(path)
    assert.equal("dos", vim.bo.fileformat)
    accept_then_client_exits(path, "alpha\nBETA accepted\n")

    close_all_then_write(path)

    assert.equal("alpha\r\nBETA accepted\r\n", read_bytes(path))
  end)

  it("writes one BOM when the proposal for a 'bomb' file starts with one", function()
    local path = dir .. "/bom.txt"
    write_bytes(path, "\239\187\191alpha\n")
    vim.cmd.edit(path)
    assert.is_true(vim.bo.bomb)
    accept_then_client_exits(path, "\239\187\191alpha accepted\n")

    close_all_then_write(path)

    assert.equal("\239\187\191alpha accepted\n", read_bytes(path))
  end)

  it("writes a text with no final line break as accepted, then the buffer's 'fixeol' applies again", function()
    local path = dir .. "/noeol.txt"
    write_bytes(path, "alpha\n")
    accept_then_client_exits(path, "alpha accepted\n", function()
      vim.bo.eol = false
    end)

    local buf = close_all_then_write(path)

    assert.equal("alpha accepted", read_bytes(path))
    assert.is_true(vim.bo[buf].fixeol, "the user's next :w adds the final line break again")
    vim.bo[buf].fixeol = false
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent edit!")
    end)
    assert.is_false(vim.bo[buf].fixeol, "the user's own 'fixeol' stays after a later :e!")
  end)

  it("tells the user to change 'fileencoding' when the file's encoding cannot hold the accepted text", function()
    local path = dir .. "/latin1.txt"
    write_bytes(path, "caf\233\n")
    vim.cmd.edit(path)
    assert.equal("latin1", vim.bo.fileencoding)
    accept_then_client_exits(path, "café costs 5 €\n")

    vim.cmd("ClaudeCodeCloseAllDiffs")

    assert.are.same({ "café costs 5 €" }, vim.api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false))
    assert.is_truthy(notes[#notes]:find(":set fileencoding=utf-8 (latin1 cannot hold them), then :w", 1, true))
  end)

  it("names a write that creates the accepted file's folder when it does not exist yet", function()
    local path = dir .. "/new folder/created.txt"
    accept_then_client_exits(path, "created\n")

    vim.cmd("ClaudeCodeCloseAllDiffs")

    -- Neovim 0.8 has no :w ++p.
    local write = vim.fn.has("nvim-0.9") == 1 and ":w ++p" or ":call mkdir(expand('%:p:h'), 'p') | w"
    assert.is_truthy(notes[#notes]:find(": " .. write .. " writes them", 1, true), notes[#notes])
    vim.api.nvim_buf_call(vim.fn.bufnr(path), function()
      vim.cmd("silent " .. write:sub(2))
    end)
    assert.equal("created\n", read_bytes(path))
  end)

  it("keeps the diff, names the error, and leaves no buffer behind when the file's buffer refuses the text", function()
    local path = dir .. "/refuses.txt"
    write_bytes(path, "alpha\n")
    local tab = accept_then_client_exits(path, "alpha accepted\n")
    vim.cmd("bwipeout! " .. vim.fn.fnameescape(path))
    vim.api.nvim_create_autocmd("BufReadPost", {
      pattern = path,
      once = true,
      callback = function()
        vim.bo.modifiable = false
      end,
    })

    vim.cmd("ClaudeCodeCloseAllDiffs")

    assert.equal("saved", diff._get_active_diffs()[tab].status)
    assert.is_truthy(notes[#notes]:find(": Buffer is not 'modifiable'$"), notes[#notes])
    assert.is_nil(notes[#notes]:find("%.lua:%d+:"), "the message names no plugin source line")
    assert.equal(0, vim.fn.bufexists(path), "the command leaves no buffer the user did not have")
    assert.equal("alpha\n", read_bytes(path))
  end)

  -- After the accept, the user is in the diff's own window. A unified diff buffer cannot be abandoned while it is
  -- modified, so the swap file step must not replace the buffer in that window.
  local swap_layouts = {
    { "vertical", { layout = "vertical" } },
    { "vertical new-tab", { layout = "vertical", open_in_new_tab = true } },
  }
  if vim.fn.has("nvim-0.9") == 1 then
    swap_layouts[#swap_layouts + 1] = { "unified", { layout = "unified" } }
  end
  for _, case in ipairs(swap_layouts) do
    local layout, diff_opts = case[1], case[2]
    it("names a swap file step that works from the " .. layout .. " diff window", function()
      local config = vim.deepcopy(require("claudecode.config").defaults)
      diff.setup(vim.tbl_deep_extend("force", config, { diff_opts = diff_opts }))
      local path = dir .. "/swapped.txt"
      write_bytes(path, "alpha\n")
      local tab = "✻ [Claude Code] swapped.txt ⧉"
      local call = tools.handle_invoke(owner, {
        name = "openDiff",
        arguments = {
          old_file_path = path,
          new_file_path = path,
          new_file_contents = "alpha accepted\n",
          tab_name = tab,
        },
      })
      assert.is_true(call._deferred, vim.inspect(call.error))
      _G.claude_deferred_responses[tostring(call.coroutine)] = function() end
      local diff_win = diff._get_active_diffs()[tab].new_window
      vim.api.nvim_set_current_win(diff_win)
      vim.cmd("write")
      diff.close_diffs_for_client(owner.id, "client disconnected")
      if vim.fn.bufexists(path) == 1 then
        vim.cmd("bwipeout! " .. vim.fn.fnameescape(path))
      end
      vim.api.nvim_set_current_win(diff_win)
      -- Another Neovim edits the file, so loading it fails until the user answers the swap file prompt.
      local swap_answered = false
      vim.fn.bufload = function(buf)
        if not swap_answered then
          error("Vim:E325: ATTENTION")
        end
        return real_bufload(buf)
      end

      vim.cmd("ClaudeCodeCloseAllDiffs")

      assert.equal("saved", diff._get_active_diffs()[tab].status)
      local step = notes[#notes]:match("open it with :(%S+ %S+) %(answer the swap file prompt")
      assert.is_not_nil(step, notes[#notes])
      assert.equal(diff_win, vim.api.nvim_get_current_win(), "the user is still in the diff window")
      swap_answered = true
      vim.cmd(step)
      vim.cmd("ClaudeCodeCloseAllDiffs")
      assert.is_nil(diff._get_active_diffs()[tab], notes[#notes])
      assert.are.same({ "alpha accepted" }, vim.api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false))
    end)
  end

  it("closes a diff the user rejected after its client exited", function()
    local path = dir .. "/rejected.txt"
    write_bytes(path, "alpha\n")
    local tab = "✻ [Claude Code] rejected.txt ⧉"
    local call = tools.handle_invoke(owner, {
      name = "openDiff",
      arguments = { old_file_path = path, new_file_path = path, new_file_contents = "x\n", tab_name = tab },
    })
    _G.claude_deferred_responses[tostring(call.coroutine)] = function() end
    vim.api.nvim_buf_call(diff._get_active_diffs()[tab].new_buffer, function()
      vim.cmd("ClaudeCodeDiffDeny")
    end)
    diff.close_diffs_for_client(owner.id, "client disconnected")
    assert.equal("rejected", diff._get_active_diffs()[tab].status)

    vim.cmd("ClaudeCodeCloseAllDiffs")

    assert.is_nil(diff._get_active_diffs()[tab])
    assert.are.same({ "Closed 1 rejected Claude diff(s)" }, notes)
  end)
end)

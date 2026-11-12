-- Neovim stops firing BufUnload at exit once an autocmd deletes the buffer it fired for (main.c, exit_loop in
-- getout), and a new-file reject with `on_new_file_reject = "keep_empty"` deletes its proposal buffer. So the
-- diffs behind that buffer get no BufUnload, reach VimLeavePre pending, and used to be removed unanswered. These
-- tests run the VimLeavePre autocmd of diff.lua over the states that exit can leave. The real exit, with real
-- buffers, is tests/integration/diff_exit_reject_spec.lua.
require("tests.busted_setup")

describe("diffs still pending when Neovim exits", function()
  local diff, dir, answers

  ---The one VimLeavePre autocmd of diff.lua, run as Neovim runs it.
  local function leave()
    local group = _G.vim._autocmds["ClaudeCodeMCPDiff"]
    assert(group, "the ClaudeCodeMCPDiff augroup was not created")
    local callbacks = {}
    for _, event in ipairs(group.events) do
      if event.events == "VimLeavePre" then
        callbacks[#callbacks + 1] = event.opts.callback
      end
    end
    assert.equal(1, #callbacks, "expected one VimLeavePre autocmd in diff.lua")
    callbacks[1]()
  end

  ---Open a pending diff of a new file name. The sender records each answer, as the server's sender would.
  local function open_pending(name)
    local path = dir .. "/" .. name
    local file = assert(io.open(path, "w"))
    file:write("line 1\nline 2\n")
    file:close()
    local co = coroutine.create(function()
      return diff.open_diff_blocking(path, path, "line 1\nline 2\nnew line\n", name, "client")
    end)
    local ok, err = coroutine.resume(co)
    assert.is_true(ok, "the diff coroutine should start: " .. tostring(err))
    assert.equal("suspended", coroutine.status(co), name .. " should be pending")
    _G.claude_deferred_responses[tostring(co)] = function(response)
      answers[#answers + 1] = { name = name, text = response.content[1].text, tab = response.content[2].text }
    end
    return co
  end

  ---What Neovim's BufUnload autocmd of a proposal buffer does, and what the keep_empty reject then does.
  local function buf_unload_with_keep_empty(name)
    diff._resolve_diff_as_rejected(name)
    diff._cleanup_diff_state(name, "diff rejected (keep_empty)")
  end

  before_each(function()
    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")
    diff.setup({ diff_opts = {} })
    dir = require("tests.helpers.temp_dir").new()
    answers = {}
    _G.claude_deferred_responses = {}
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test cleanup")
    require("tests.helpers.temp_dir").remove(dir)
    _G.claude_deferred_responses = nil
  end)

  it("answers a diff that never got its BufUnload with DIFF_REJECTED, and removes it", function()
    open_pending("a.txt")

    leave()

    assert.same({ { name = "a.txt", text = "DIFF_REJECTED", tab = "a.txt" } }, answers)
    assert.is_nil(next(diff._get_active_diffs()))
  end)

  it("answers every pending diff when an earlier diff's reject deleted its buffer and stopped the exit loop", function()
    open_pending("new1.txt")
    open_pending("b.txt")
    buf_unload_with_keep_empty("new1.txt") -- the only BufUnload that ran

    leave()

    local names = {}
    for _, answer in ipairs(answers) do
      assert.equal("DIFF_REJECTED", answer.text)
      names[#names + 1] = answer.name
    end
    assert.same({ "new1.txt", "b.txt" }, names, "each diff gets one answer")
    assert.is_nil(next(diff._get_active_diffs()))
  end)

  it("answers the oldest pending diff first", function()
    open_pending("first.txt")
    open_pending("second.txt")
    open_pending("third.txt")

    leave()

    local names = {}
    for _, answer in ipairs(answers) do
      names[#names + 1] = answer.name
    end
    assert.same({ "first.txt", "second.txt", "third.txt" }, names)
  end)

  it("sends no second answer for a diff that its BufUnload already rejected", function()
    open_pending("a.txt")
    diff._resolve_diff_as_rejected("a.txt") -- the BufUnload autocmd, without a keep_empty cleanup

    leave()

    assert.equal(1, #answers, "one answer for one openDiff")
    assert.is_nil(next(diff._get_active_diffs()))
  end)

  it("sends no second answer to a diff that the user accepted with :w", function()
    open_pending("a.txt")
    diff._resolve_diff_as_saved("a.txt", diff._get_active_diffs()["a.txt"].new_buffer)

    leave()

    assert.equal(1, #answers, "one answer for one openDiff")
    assert.equal("FILE_SAVED", answers[1].text)
  end)

  it("still answers the other pending diffs when rejecting one raises", function()
    open_pending("a.txt")
    open_pending("b.txt")
    diff._get_active_diffs()["a.txt"].resolution_callback = function()
      error("boom")
    end

    assert.has_no.errors(leave)

    assert.same({ { name = "b.txt", text = "DIFF_REJECTED", tab = "b.txt" } }, answers)
  end)
end)

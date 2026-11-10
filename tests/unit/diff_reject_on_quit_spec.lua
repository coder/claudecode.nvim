-- luacheck: globals expect
-- Regression test for issue #238: rejecting a Claude diff with `:q` must resolve
-- the diff as rejected. The proposed buffer is a scratch buffer (bufhidden="hide"),
-- so `:q` only HIDES it and never fires BufDelete/BufUnload/BufWipeout -- rejection
-- therefore relies on a WinClosed autocmd, gated on the proposed buffer no longer
-- being visible in any window (so splitting it and closing one clone does not
-- prematurely reject).
--
-- This is a unit test of the WinClosed handler logic. The end-to-end behavior
-- (that a real `:q` actually triggers it) is covered by the headless gate
-- scripts/repro_issue_238.lua and the fixtures/issue-238 fixture.
require("tests.busted_setup")

describe("diff reject on window close (issue #238)", function()
  local diff
  local saved_win_findbuf
  local saved_buf_is_valid

  -- All opts the diff registered for a given event in the "ClaudeCodeMCPDiff" augroup.
  local function autocmd_entries(event_name)
    local group = _G.vim._autocmds and _G.vim._autocmds["ClaudeCodeMCPDiff"]
    assert(group, "ClaudeCodeMCPDiff augroup was not created")
    local found = {}
    for _, ev in ipairs(group.events) do
      if ev.events == event_name then
        found[#found + 1] = ev.opts
      end
    end
    return found
  end

  -- Opts for the first registration of an event (callers below register a single diff).
  local function autocmd_opts(event_name)
    return autocmd_entries(event_name)[1]
  end

  -- The WinClosed callback, asserting EXACTLY ONE is registered. autocmd lookup is
  -- by event name, so a stale/duplicate registration would otherwise hand back the
  -- wrong diff's callback (and mask a leaked, never-cleaned-up handler) -- fail loudly.
  local function winclosed_callback()
    local found = autocmd_entries("WinClosed")
    assert(#found == 1, "expected exactly one WinClosed autocmd, got " .. #found)
    return found[1].callback
  end

  -- Every registered WinClosed callback, in registration order (for multi-diff tests:
  -- a real window close fires them all).
  local function winclosed_callbacks()
    local cbs = {}
    for _, opts in ipairs(autocmd_entries("WinClosed")) do
      cbs[#cbs + 1] = opts.callback
    end
    return cbs
  end

  before_each(function()
    package.loaded["claudecode.diff"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
      info = function() end,
    }

    saved_win_findbuf = _G.vim.fn.win_findbuf
    saved_buf_is_valid = _G.vim.api.nvim_buf_is_valid
    _G.vim.api.nvim_buf_is_valid = function()
      return true
    end

    diff = require("claudecode.diff")
    diff.setup({ diff_opts = {} })
  end)

  after_each(function()
    -- _G.vim is shared across the whole busted run; restore what we stubbed.
    _G.vim.fn.win_findbuf = saved_win_findbuf
    _G.vim.api.nvim_buf_is_valid = saved_buf_is_valid
  end)

  -- Register the reject autocmds and a pending diff state that captures its
  -- resolution. autocmd_ids is captured from _register_diff_autocmds (as the real
  -- _setup_blocking_diff does) so _cleanup_diff_state can tear the handlers down.
  local function register_pending(tab_name, new_buffer, status)
    local captured = { result = nil }
    local autocmd_ids = diff._register_diff_autocmds(tab_name, new_buffer)
    diff._register_diff_state(tab_name, {
      status = status or "pending",
      resolution_callback = function(result)
        captured.result = result
      end,
      new_buffer = new_buffer,
      is_new_file = false,
      autocmd_ids = autocmd_ids,
    })
    return captured
  end

  -- Single-diff convenience: register one diff and return its captured-result table
  -- plus its (sole) WinClosed callback.
  local function setup_pending_diff(tab_name, new_buffer, status)
    local captured = register_pending(tab_name, new_buffer, status)
    return captured, winclosed_callback()
  end

  it("rejects the diff when the proposed window closes and the buffer is no longer visible", function()
    local captured, cb = setup_pending_diff("issue238-a", 42)
    expect(cb).to_be_function()

    _G.vim.fn.win_findbuf = function()
      return {} -- buffer shown in no window after the close
    end
    cb({ match = "1001" })

    expect(captured.result).to_be_table()
    expect(captured.result.content[1].text).to_be("DIFF_REJECTED")
    expect(diff._get_active_diffs()["issue238-a"].status).to_be("rejected")
  end)

  it("rejects when only the closing window showed the buffer (the last window)", function()
    local captured, cb = setup_pending_diff("issue238-b", 43)

    -- WinClosed fires BEFORE the window leaves the layout, so win_findbuf still
    -- lists the closing window; it must be excluded from the visibility check.
    _G.vim.fn.win_findbuf = function()
      return { 1001 }
    end
    cb({ match = "1001" })

    expect(captured.result).to_be_table()
    expect(captured.result.content[1].text).to_be("DIFF_REJECTED")
    expect(diff._get_active_diffs()["issue238-b"].status).to_be("rejected")
  end)

  it("does NOT reject when the buffer is still visible in another window (split)", function()
    local captured, cb = setup_pending_diff("issue238-c", 44)

    -- Closing window 1001, but the buffer is also shown in window 2002.
    _G.vim.fn.win_findbuf = function()
      return { 1001, 2002 }
    end
    cb({ match = "1001" })

    expect(captured.result).to_be_nil()
    expect(diff._get_active_diffs()["issue238-c"].status).to_be("pending")
  end)

  it("is a no-op when the diff was already accepted (:w)", function()
    -- Accept sets status="saved"; a later window close must not flip it to rejected.
    local captured, cb = setup_pending_diff("issue238-d", 45, "saved")

    _G.vim.fn.win_findbuf = function()
      return {}
    end
    cb({ match = "1001" })

    expect(captured.result).to_be_nil()
    expect(diff._get_active_diffs()["issue238-d"].status).to_be("saved")
  end)

  it("is a no-op when the proposed buffer is already invalid", function()
    local captured, cb = setup_pending_diff("issue238-e", 46)

    -- If the buffer is already gone, the handler must bail before touching win_findbuf.
    _G.vim.api.nvim_buf_is_valid = function()
      return false
    end
    _G.vim.fn.win_findbuf = function()
      error("win_findbuf must not be called when the buffer is invalid")
    end
    cb({ match = "1001" })

    expect(captured.result).to_be_nil()
    expect(diff._get_active_diffs()["issue238-e"].status).to_be("pending")
  end)

  it("registers WinClosed window-wide (no buffer/pattern) while Buf* events stay buffer-scoped", function()
    -- The pattern-less registration is load-bearing: WinClosed must observe *any* window's
    -- close so it can re-check visibility (a buffer= or pattern= scope would reintroduce the
    -- multi-window premature-reject bug). The Buf* deletion events stay buffer-scoped.
    setup_pending_diff("issue238-f", 47)

    local winclosed = autocmd_opts("WinClosed")
    expect(winclosed).to_be_table()
    expect(winclosed.buffer).to_be_nil()
    expect(winclosed.pattern).to_be_nil()

    expect(autocmd_opts("BufDelete").buffer).to_be(47)
    expect(autocmd_opts("BufUnload").buffer).to_be(47)
    expect(autocmd_opts("BufWipeout").buffer).to_be(47)
  end)

  it("does NOT reject when an unrelated window (not showing the buffer) closes", function()
    -- WinClosed is window-wide, so it fires for every window close. Closing a window
    -- that never showed the proposed buffer must not touch this diff.
    local captured, cb = setup_pending_diff("issue238-g", 48)

    _G.vim.fn.win_findbuf = function()
      return { 1001 } -- proposed buffer still in its own untouched window
    end
    cb({ match = "9999" }) -- an unrelated window closed

    expect(captured.result).to_be_nil()
    expect(diff._get_active_diffs()["issue238-g"].status).to_be("pending")
  end)

  it("with two pending diffs, a window close rejects only the one no longer visible", function()
    -- The window-wide registration exists precisely so concurrent diffs stay isolated:
    -- a real close fires EVERY diff's WinClosed, each re-checking its own buffer.
    local cap_a = register_pending("issue238-A", 60)
    local cap_b = register_pending("issue238-B", 61)
    local cbs = winclosed_callbacks()
    expect(#cbs).to_be(2)

    _G.vim.fn.win_findbuf = function(buf)
      if buf == 60 then
        return {} -- A's buffer no longer shown
      end
      return { 2002 } -- B's buffer still shown elsewhere
    end
    for _, cb in ipairs(cbs) do
      cb({ match = "1001" })
    end

    expect(cap_a.result).to_be_table()
    expect(cap_a.result.content[1].text).to_be("DIFF_REJECTED")
    expect(diff._get_active_diffs()["issue238-A"].status).to_be("rejected")
    expect(cap_b.result).to_be_nil()
    expect(diff._get_active_diffs()["issue238-B"].status).to_be("pending")
  end)

  it("captures the WinClosed autocmd id so _cleanup_diff_state tears it down", function()
    -- If the WinClosed id were dropped from autocmd_ids, cleanup would leak the
    -- window-wide handler and it would keep firing against later diffs.
    register_pending("issue238-h", 62)
    expect(#autocmd_entries("WinClosed")).to_be(1)

    diff._cleanup_diff_state("issue238-h", "test cleanup")

    expect(#autocmd_entries("WinClosed")).to_be(0)
  end)
end)

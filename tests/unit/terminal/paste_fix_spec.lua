require("tests.busted_setup")
require("tests.mocks.vim")

-- Tests for the streamed-paste compatibility shim (issue #161).
describe("claudecode.terminal.paste_fix", function()
  local paste_fix

  -- Reload the module fresh each test so its `installed`/`chunks` state resets.
  local function fresh()
    package.loaded["claudecode.terminal.paste_fix"] = nil
    paste_fix = require("claudecode.terminal.paste_fix")
  end

  local saved_version, saved_paste, saved_bo, saved_get_buf

  before_each(function()
    saved_version = vim.version
    saved_paste = vim.paste
    saved_bo = vim.bo
    saved_get_buf = vim.api.nvim_get_current_buf
    fresh()
  end)

  after_each(function()
    vim.version = saved_version
    vim.paste = saved_paste
    vim.bo = saved_bo
    vim.api.nvim_get_current_buf = saved_get_buf
    package.loaded["claudecode.terminal.paste_fix"] = nil
    package.loaded["claudecode.terminal"] = nil
  end)

  describe("_accumulate (seam-join)", function()
    it("appends all lines when the accumulator is empty", function()
      local acc = {}
      paste_fix._accumulate(acc, { "alpha", "beta" })
      assert.are.same({ "alpha", "beta" }, acc)
    end)

    it("joins the first incoming line onto the last buffered line (mid-line seam)", function()
      -- Source "hello world\nsecond line" streamed as:
      --   chunk1 "hello world\nsec"  -> {"hello world", "sec"}
      --   chunk2 "ond line"          -> {"ond line"}
      local acc = {}
      paste_fix._accumulate(acc, { "hello world", "sec" })
      paste_fix._accumulate(acc, { "ond line" })
      assert.are.same({ "hello world", "second line" }, acc)
    end)

    it("preserves genuine newlines within a single chunk", function()
      local acc = {}
      paste_fix._accumulate(acc, { "one", "two", "three" })
      assert.are.same({ "one", "two", "three" }, acc)
    end)

    it("does nothing for an empty lines table", function()
      local acc = { "kept" }
      paste_fix._accumulate(acc, {})
      assert.are.same({ "kept" }, acc)
    end)

    it("reconstructs a single long line split across many chunks", function()
      -- One source line with no newlines, fragmented mid-line repeatedly.
      local acc = {}
      paste_fix._accumulate(acc, { "the quick " })
      paste_fix._accumulate(acc, { "brown fox " })
      paste_fix._accumulate(acc, { "jumps" })
      assert.are.same({ "the quick brown fox jumps" }, acc)
    end)

    it("handles a blank line straddling a chunk boundary", function()
      -- Source "a\n\nb" streamed as chunk1 "a\n" -> {"a",""}, chunk2 "\nb" -> {"","b"}
      local acc = {}
      paste_fix._accumulate(acc, { "a", "" })
      paste_fix._accumulate(acc, { "", "b" })
      -- seam joins "" .. "" => still empty; result keeps both blank separations
      assert.are.same({ "a", "", "b" }, acc)
    end)
  end)

  describe("should_enable", function()
    it("returns false when explicitly disabled", function()
      assert.is_false(paste_fix.should_enable(false))
    end)

    it("returns true when explicitly forced", function()
      assert.is_true(paste_fix.should_enable(true))
    end)

    it("delegates to version detection for 'auto' and nil", function()
      vim.version = function()
        return { major = 0, minor = 11, patch = 7 }
      end
      assert.is_true(paste_fix.should_enable("auto"))
      assert.is_true(paste_fix.should_enable(nil))

      vim.version = function()
        return { major = 0, minor = 12, patch = 2 }
      end
      assert.is_false(paste_fix.should_enable("auto"))
      assert.is_false(paste_fix.should_enable(nil))
    end)
  end)

  describe("is_affected_version", function()
    local cases = {
      { { 0, 8, 0 }, true },
      { { 0, 11, 5 }, true },
      { { 0, 11, 7 }, true },
      { { 0, 12, 0 }, true },
      { { 0, 12, 1 }, true },
      { { 0, 12, 2 }, false },
      { { 0, 12, 3 }, false },
      { { 0, 13, 0 }, false },
      { { 1, 0, 0 }, false },
    }
    for _, case in ipairs(cases) do
      local ver, expected = case[1], case[2]
      it(string.format("%d.%d.%d -> affected=%s", ver[1], ver[2], ver[3], tostring(expected)), function()
        vim.version = function()
          return { major = ver[1], minor = ver[2], patch = ver[3] }
        end
        assert.are.equal(expected, paste_fix.is_affected_version())
      end)
    end
  end)

  describe("install (cooperative override)", function()
    local managed_bufnr, current_bufnr, buftype_by_buf, orig_calls

    -- Build a controlled vim environment for the override and install the shim.
    local function setup_env()
      managed_bufnr = 10
      current_bufnr = 10
      buftype_by_buf = { [10] = "terminal" }
      orig_calls = {}

      vim.api.nvim_get_current_buf = function()
        return current_bufnr
      end
      vim.bo = setmetatable({}, {
        __index = function(_, b)
          return { buftype = buftype_by_buf[b] or "" }
        end,
      })
      -- The original paste handler the shim must delegate to / replay through.
      vim.paste = function(lines, phase)
        orig_calls[#orig_calls + 1] = { lines = lines, phase = phase }
        return true
      end
      -- Stub the terminal module so is_managed_terminal resolves without loading
      -- the real (heavy) module.
      package.loaded["claudecode.terminal"] = {
        get_active_terminal_bufnr = function()
          return managed_bufnr
        end,
      }
      -- apply(true) sets enabled and installs the override.
      paste_fix.apply(true)
    end

    it("coalesces a streamed paste into one phase==-1 replay for the managed terminal", function()
      setup_env()
      -- Source "hello world\nsecond line" streamed across two chunks.
      assert.is_true(vim.paste({ "hello world", "sec" }, 1))
      assert.is_true(vim.paste({ "ond line" }, 3))

      assert.are.equal(1, #orig_calls)
      assert.are.equal(-1, orig_calls[1].phase)
      assert.are.same({ "hello world", "second line" }, orig_calls[1].lines)
    end)

    it("coalesces a three-phase (1->2->3) stream including the middle phase", function()
      setup_env()
      -- Source "foo\nbar\nbaz" streamed across three chunks, each split mid-line.
      assert.is_true(vim.paste({ "foo", "ba" }, 1))
      assert.is_true(vim.paste({ "r", "ba" }, 2))
      assert.is_true(vim.paste({ "z" }, 3))

      assert.are.equal(1, #orig_calls)
      assert.are.equal(-1, orig_calls[1].phase)
      assert.are.same({ "foo", "bar", "baz" }, orig_calls[1].lines)
    end)

    it("delegates a non-streamed (phase==-1) paste unchanged", function()
      setup_env()
      vim.paste({ "whole" }, -1)
      assert.are.equal(1, #orig_calls)
      assert.are.equal(-1, orig_calls[1].phase)
      assert.are.same({ "whole" }, orig_calls[1].lines)
    end)

    it("coalesces into a single replay even if focus leaves mid-stream", function()
      setup_env()
      -- Phase 1 targets the managed terminal; the streaming decision is latched.
      assert.is_true(vim.paste({ "kept ", "dat" }, 1))
      -- Focus moves to a normal buffer before phase 3.
      current_bufnr = 99
      buftype_by_buf[99] = ""
      vim.paste({ "a" }, 3)
      -- Still one coalesced replay through the original handler (delivery is
      -- delegated to vim.paste rather than reconstructed by us).
      assert.are.equal(1, #orig_calls)
      assert.are.equal(-1, orig_calls[1].phase)
      assert.are.same({ "kept ", "data" }, orig_calls[1].lines)
    end)

    it("respects a later apply(false): delegates instead of coalescing", function()
      setup_env()
      paste_fix.apply(false) -- disable without uninstalling
      assert.is_false(paste_fix._is_enabled())
      vim.paste({ "a", "b" }, 1)
      vim.paste({ "c" }, 3)
      -- No coalescing: each phase passes straight through.
      assert.are.equal(2, #orig_calls)
      assert.are.equal(1, orig_calls[1].phase)
      assert.are.equal(3, orig_calls[2].phase)
    end)

    it("delegates pastes into a non-managed terminal unchanged", function()
      setup_env()
      current_bufnr = 99 -- not the managed terminal
      buftype_by_buf[99] = "terminal"
      vim.paste({ "x" }, 1)
      vim.paste({ "y" }, 3)
      -- Each phase passed straight through; no coalescing.
      assert.are.equal(2, #orig_calls)
      assert.are.equal(1, orig_calls[1].phase)
      assert.are.equal(3, orig_calls[2].phase)
    end)

    it("delegates pastes into a normal (non-terminal) buffer unchanged", function()
      setup_env()
      current_bufnr = 10
      buftype_by_buf[10] = "" -- normal buffer
      vim.paste({ "code" }, 1)
      assert.are.equal(1, #orig_calls)
      assert.are.equal(1, orig_calls[1].phase)
    end)

    it("is idempotent (does not double-wrap vim.paste)", function()
      setup_env()
      local after_first = vim.paste
      paste_fix.install()
      assert.are.equal(after_first, vim.paste)
      assert.is_true(paste_fix._is_installed())
    end)
  end)
end)

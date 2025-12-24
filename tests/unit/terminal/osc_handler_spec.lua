---Tests for the OSC handler module.
---@module 'tests.unit.terminal.osc_handler_spec'

-- Setup test environment
require("tests.busted_setup")

describe("OSC Handler", function()
  local osc_handler

  before_each(function()
    -- Reset module state before each test
    package.loaded["claudecode.terminal.osc_handler"] = nil
    osc_handler = require("claudecode.terminal.osc_handler")
    osc_handler._reset()
  end)

  describe("parse_osc_title", function()
    it("should return nil for nil input", function()
      local result = osc_handler.parse_osc_title(nil)
      assert.is_nil(result)
    end)

    it("should return nil for empty string", function()
      local result = osc_handler.parse_osc_title("")
      assert.is_nil(result)
    end)

    it("should parse OSC 0 with BEL terminator", function()
      -- OSC 0: ESC ] 0 ; title BEL
      local data = "\027]0;My Title\007"
      local result = osc_handler.parse_osc_title(data)
      assert.are.equal("My Title", result)
    end)

    it("should parse OSC 2 with BEL terminator", function()
      -- OSC 2: ESC ] 2 ; title BEL
      local data = "\027]2;Window Title\007"
      local result = osc_handler.parse_osc_title(data)
      assert.are.equal("Window Title", result)
    end)

    it("should parse OSC 0 with ST terminator", function()
      -- OSC 0: ESC ] 0 ; title ESC \
      local data = "\027]0;My Title\027\\"
      local result = osc_handler.parse_osc_title(data)
      assert.are.equal("My Title", result)
    end)

    it("should parse OSC 2 with ST terminator", function()
      -- OSC 2: ESC ] 2 ; title ESC \
      local data = "\027]2;Window Title\027\\"
      local result = osc_handler.parse_osc_title(data)
      assert.are.equal("Window Title", result)
    end)

    it("should handle Claude-specific title format", function()
      local data = "\027]2;Claude - implement vim mode\007"
      local result = osc_handler.parse_osc_title(data)
      assert.are.equal("Claude - implement vim mode", result)
    end)

    it("should return nil for non-OSC sequences", function()
      local result = osc_handler.parse_osc_title("Just plain text")
      assert.is_nil(result)
    end)

    it("should return nil for other OSC types (not 0 or 2)", function()
      -- OSC 7 is for working directory, not title
      local data = "\027]7;file:///path\007"
      local result = osc_handler.parse_osc_title(data)
      assert.is_nil(result)
    end)

    it("should handle empty title", function()
      local data = "\027]2;\007"
      local result = osc_handler.parse_osc_title(data)
      assert.is_nil(result)
    end)

    it("should handle title with special characters", function()
      local data = "\027]2;Project: my-app (dev)\007"
      local result = osc_handler.parse_osc_title(data)
      assert.are.equal("Project: my-app (dev)", result)
    end)

    it("should handle title without ESC prefix", function()
      -- Some terminals may strip the ESC prefix
      local data = "]2;My Title"
      local result = osc_handler.parse_osc_title(data)
      assert.are.equal("My Title", result)
    end)

    it("should trim whitespace from title", function()
      local data = "\027]2;  spaced title  \007"
      local result = osc_handler.parse_osc_title(data)
      assert.are.equal("spaced title", result)
    end)
  end)

  describe("clean_title", function()
    it("should strip Claude - prefix", function()
      local result = osc_handler.clean_title("Claude - my project")
      assert.are.equal("my project", result)
    end)

    it("should strip claude - prefix (lowercase)", function()
      local result = osc_handler.clean_title("claude - my project")
      assert.are.equal("my project", result)
    end)

    it("should not strip Claude prefix without dash", function()
      local result = osc_handler.clean_title("Claude project")
      assert.are.equal("Claude project", result)
    end)

    it("should trim whitespace", function()
      local result = osc_handler.clean_title("  my title  ")
      assert.are.equal("my title", result)
    end)

    it("should limit length to 100 characters", function()
      local long_title = string.rep("a", 150)
      local result = osc_handler.clean_title(long_title)
      assert.are.equal(100, #result)
      assert.truthy(result:match("%.%.%.$"))
    end)

    it("should handle nil input", function()
      local result = osc_handler.clean_title(nil)
      assert.is_nil(result)
    end)
  end)

  describe("has_handler", function()
    it("should return false for buffer without handler", function()
      local result = osc_handler.has_handler(123)
      assert.is_false(result)
    end)
  end)

  describe("_get_handler_count", function()
    it("should return 0 when no handlers registered", function()
      assert.are.equal(0, osc_handler._get_handler_count())
    end)
  end)

  describe("_reset", function()
    it("should clear all handlers", function()
      -- Since we can't easily set up handlers without a real terminal,
      -- we just verify reset doesn't error and maintains count at 0
      osc_handler._reset()
      assert.are.equal(0, osc_handler._get_handler_count())
    end)
  end)

  describe("cleanup_buffer_handler", function()
    it("should not error when cleaning up non-existent handler", function()
      -- Should not throw an error
      assert.has_no.errors(function()
        osc_handler.cleanup_buffer_handler(999)
      end)
    end)

    it("should be idempotent (double cleanup should not error)", function()
      assert.has_no.errors(function()
        osc_handler.cleanup_buffer_handler(123)
        osc_handler.cleanup_buffer_handler(123)
      end)
    end)
  end)
end)

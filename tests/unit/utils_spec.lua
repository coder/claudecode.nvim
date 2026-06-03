-- Tests for claudecode.utils helpers.

describe("claudecode.utils.shell_split", function()
  local utils = require("claudecode.utils")

  it("splits a plain command on whitespace", function()
    assert.are.same({ "claude", "--resume", "--verbose" }, utils.shell_split("claude --resume --verbose"))
  end)

  it("returns a single-element argv for an argument-less command", function()
    assert.are.same({ "claude" }, utils.shell_split("claude"))
  end)

  it("collapses runs of whitespace between words", function()
    assert.are.same({ "claude", "--resume" }, utils.shell_split("claude    --resume"))
  end)

  it("preserves bracketed model aliases verbatim (no glob expansion)", function()
    assert.are.same({ "claude", "--model", "opus[1m]" }, utils.shell_split("claude --model opus[1m]"))
  end)

  it("keeps single-quoted arguments containing spaces intact", function()
    assert.are.same(
      { "claude", "--message=hello world", "--path=/tmp/test" },
      utils.shell_split("claude --message='hello world' --path=/tmp/test")
    )
  end)

  it("keeps double-quoted arguments containing spaces intact", function()
    assert.are.same({ "claude", "--foo", "a b", "bar" }, utils.shell_split('claude --foo "a b" bar'))
  end)

  it("unescapes recognized backslash sequences inside double quotes", function()
    assert.are.same({ 'a"b' }, utils.shell_split('"a\\"b"'))
  end)

  it("concatenates adjacent quoted and unquoted segments", function()
    assert.are.same({ "claude", "--x=ab" }, utils.shell_split("claude --x='a''b'"))
  end)

  it("honors backslash-escaped spaces outside quotes", function()
    assert.are.same({ "claude", "a b" }, utils.shell_split("claude a\\ b"))
  end)

  it("returns an empty argv for an empty string", function()
    assert.are.same({}, utils.shell_split(""))
  end)
end)

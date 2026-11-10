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

describe("claudecode.utils.expand_tilde", function()
  local utils = require("claudecode.utils")
  local home = os.getenv("HOME")

  it("expands a bare tilde to $HOME", function()
    assert.are.equal(home, utils.expand_tilde("~"))
  end)

  it("expands a leading ~/ to $HOME/...", function()
    assert.are.equal(home .. "/.claude/local/claude", utils.expand_tilde("~/.claude/local/claude"))
  end)

  it("leaves a tilde that is not at the start of the word untouched", function()
    assert.are.equal("--path=~/x", utils.expand_tilde("--path=~/x"))
  end)

  it("leaves the ~user form untouched", function()
    assert.are.equal("~root/x", utils.expand_tilde("~root/x"))
  end)

  it("returns non-tilde arguments unchanged", function()
    assert.are.equal("--model", utils.expand_tilde("--model"))
  end)

  it("preserves a literal $ in the path (does not expand env vars)", function()
    -- TanStack Router `$param` route files would otherwise be mangled by
    -- vim.fn.expand treating `$post` as an undefined environment variable.
    assert.are.equal("src/routes/$post.tsx", utils.expand_tilde("src/routes/$post.tsx"))
    assert.are.equal("src/routes/$post/index.tsx", utils.expand_tilde("src/routes/$post/index.tsx"))
    assert.are.equal(home .. "/routes/$post.tsx", utils.expand_tilde("~/routes/$post.tsx"))
  end)
end)

describe("claudecode.utils.parse_command", function()
  local utils = require("claudecode.utils")
  local home = os.getenv("HOME")

  it("splits and expands the documented local-install terminal_cmd", function()
    assert.are.same({ home .. "/.claude/local/claude" }, utils.parse_command("~/.claude/local/claude"))
  end)

  it("expands a tilde executable while preserving quoted args and aliases", function()
    assert.are.same(
      { home .. "/.claude/local/claude", "--message=hello world", "--model", "opus[1m]" },
      utils.parse_command("~/.claude/local/claude --message='hello world' --model opus[1m]")
    )
  end)

  it("keeps bracketed aliases intact (no glob expansion)", function()
    assert.are.same({ "claude", "--model", "opus[1m]" }, utils.parse_command("claude --model opus[1m]"))
  end)
end)

describe("claudecode.utils.map_terminal_suspend", function()
  local utils = require("claudecode.utils")
  local original_vim
  local sets
  local existing_mapping
  local lookups

  before_each(function()
    original_vim = _G.vim
    sets = {}
    lookups = {}
    existing_mapping = {}
    _G.vim = {
      api = {
        nvim_buf_call = function(bufnr, fn)
          lookups.bufnr = bufnr
          return fn()
        end,
      },
      fn = {
        maparg = function(lhs, mode, abbreviation, as_dict)
          lookups.query = { lhs = lhs, mode = mode, abbreviation = abbreviation, as_dict = as_dict }
          return existing_mapping
        end,
      },
      keymap = {
        set = function(mode, lhs, rhs, opts)
          table.insert(sets, { mode = mode, lhs = lhs, rhs = rhs, opts = opts })
        end,
      },
    }
  end)

  after_each(function()
    _G.vim = original_vim
  end)

  it("maps <C-z> in terminal mode on that buffer to :suspend", function()
    utils.map_terminal_suspend(7)

    assert.are.equal(1, #sets)
    assert.are.equal("t", sets[1].mode)
    assert.are.equal("<C-z>", sets[1].lhs)
    assert.are.equal("<Cmd>suspend<CR>", sets[1].rhs)
    assert.are.equal(7, sets[1].opts.buffer)
    assert.is_string(sets[1].opts.desc)
  end)

  it("asks for the mapping the buffer already has, as a dictionary", function()
    utils.map_terminal_suspend(7)

    assert.are.equal(7, lookups.bufnr)
    assert.are.same({ lhs = "<C-z>", mode = "t", abbreviation = false, as_dict = true }, lookups.query)
  end)

  it("keeps a buffer-local terminal-mode <C-z> mapping that already exists", function()
    existing_mapping = { lhs = "<C-Z>", rhs = "<C-z>", buffer = 1 }

    utils.map_terminal_suspend(7)

    assert.are.equal(0, #sets)
  end)

  it("still maps the buffer when the existing <C-z> mapping is global", function()
    existing_mapping = { lhs = "<C-Z>", rhs = "<Cmd>ToggleTerm<CR>", buffer = 0 }

    utils.map_terminal_suspend(7)

    assert.are.equal(1, #sets)
    assert.are.equal(7, sets[1].opts.buffer)
  end)
end)

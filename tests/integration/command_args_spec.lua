-- Real-Neovim checks that :ClaudeCode and :ClaudeCodeOpen hand their arguments to the native terminal's command and
-- that the terminal starts in the configured directory. Neovim's own command line passes the arguments, so under
-- busted's mock vim this is pending; scripts/run_integration_tests_individually.sh runs it in Neovim.
-- tests/unit/command_args_spec.lua covers the same commands with a mock vim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("ClaudeCode command arguments", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("ClaudeCode command arguments", function()
  local terminal = require("claudecode.terminal")
  local real_termopen
  local termopen_calls

  before_each(function()
    termopen_calls = {}
    real_termopen = vim.fn.termopen
    vim.fn.termopen = function(cmd, opts)
      table.insert(termopen_calls, { cmd = cmd, opts = opts })
      return 1000 + #termopen_calls
    end
    require("claudecode")._create_commands()
  end)

  after_each(function()
    terminal.close()
    vim.fn.termopen = real_termopen
    terminal.defaults.cwd, terminal.defaults.cwd_provider = nil, nil
    terminal.setup({ provider = "native" }, nil)
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
  end)

  ---@param command string
  ---@return table job
  local function start(command)
    vim.cmd(command)
    assert.are.equal(1, #termopen_calls, "the command started one terminal job")
    return termopen_calls[1]
  end

  describe("with the native terminal provider", function()
    it("appends the arguments to terminal_cmd", function()
      terminal.setup({ provider = "native" }, "test_claude_cmd")

      assert.are.same({ "test_claude_cmd", "--resume", "--verbose" }, start("ClaudeCode --resume --verbose").cmd)
    end)

    it("runs the default claude command with the arguments of :ClaudeCodeOpen", function()
      terminal.setup({ provider = "native" }, nil)

      assert.are.same({ "claude", "--help" }, start("ClaudeCodeOpen --help").cmd)
    end)

    it("runs the command alone when there are no arguments", function()
      terminal.setup({ provider = "native" }, "claude")

      assert.are.same({ "claude" }, start("ClaudeCode").cmd)
    end)
  end)

  describe("edge cases", function()
    it("keeps a quoted argument with a space as one argument", function()
      terminal.setup({ provider = "native" }, "claude")

      local job = start("ClaudeCode --message='hello world' --path=/tmp/test")

      assert.are.same({ "claude", "--message=hello world", "--path=/tmp/test" }, job.cmd)
    end)

    it("passes a very long argument string through", function()
      terminal.setup({ provider = "native" }, "claude")

      local job = start("ClaudeCode " .. string.rep("--flag ", 50) .. "--final")

      assert.are.equal(52, #job.cmd)
      assert.are.equal("--final", job.cmd[#job.cmd])
    end)
  end)

  describe("backward compatibility", function()
    it("keeps :ClaudeCodeClose without arguments", function()
      assert.are.equal("0", vim.api.nvim_get_commands({}).ClaudeCodeClose.nargs)
      assert.is_false(pcall(vim.cmd, "ClaudeCodeClose --now"))
    end)

    it("starts the terminal in terminal.cwd", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      terminal.setup({ provider = "native", cwd = dir }, "claude")

      local job = start("ClaudeCode")
      vim.fn.delete(dir, "rf")

      assert.are.equal(dir, job.opts.cwd)
    end)

    it("starts the terminal in the directory terminal.cwd_provider returns", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      terminal.setup({
        provider = "native",
        cwd_provider = function()
          return dir
        end,
      }, "claude")

      local job = start("ClaudeCode")
      vim.fn.delete(dir, "rf")

      assert.are.equal(dir, job.opts.cwd)
    end)
  end)
end)

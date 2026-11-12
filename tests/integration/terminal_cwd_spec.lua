if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the terminal working directory", function()
    pending("needs a real Neovim")
  end)
  return
end

if vim.fn.has("win32") == 1 then
  describe("the terminal working directory", function()
    pending("these names are not legal on Windows")
  end)
  return
end

-- The terminal starts in the folder that the `cwd_provider` result or the static `cwd` names. `build_config` ran both
-- through `vim.fn.expand`, which reads `[`, `{`, `*`, `?`, `$` and `\` in a name as patterns or variables. So a folder
-- named `$HOME-like` or `back\slash` came back as another path, and `[x] {y}` and `it's` came back with a trailing
-- slash. A folder that exists is now taken as written. Text that names no folder still goes through `vim.fn.expand`,
-- so `~` and `$VAR` keep working. Neovim's own `expand` and `isdirectory` decide this, so under busted's mock vim this
-- is pending; scripts/run_integration_tests_individually.sh runs it in Neovim.
describe("the terminal working directory", function()
  local terminal = require("claudecode.terminal")
  local root, real_termopen, termopen_calls, saved

  -- Each name is legal in a path on Linux and macOS.
  local names = {
    { name = "no unusual character", folder = "plain" },
    { name = "a space", folder = "with space" },
    { name = "a comma", folder = "comma,dir" },
    { name = "a single quote", folder = "it's" },
    { name = "brackets and braces", folder = "[x] {y}" },
    { name = "a star and a question mark", folder = "star*mark?" },
    { name = "a percent sign and a hash", folder = "percent%d#hash" },
    { name = "a backslash", folder = "back\\slash" },
    { name = "a dollar sign", folder = "$HOME-like" },
    { name = "a leading tilde", folder = "~tilde" },
  }

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    saved = { home = vim.env.HOME, base = vim.env.CLAUDECODE_CWD_SPEC_BASE }
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
    vim.env.HOME, vim.env.CLAUDECODE_CWD_SPEC_BASE = saved.home, saved.base
    terminal.defaults.cwd, terminal.defaults.cwd_provider = nil, nil
    terminal.setup({ provider = "native" }, nil)
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(root, "rf")
  end)

  --- Opens the terminal with these terminal options and returns the folder that it started in.
  ---@param terminal_opts table
  ---@return string|nil
  local function started_in(terminal_opts)
    terminal.setup(vim.tbl_extend("force", { provider = "native" }, terminal_opts), "claude")
    vim.cmd("ClaudeCodeOpen")
    assert.are.equal(1, #termopen_calls, "the command started one terminal job")
    return termopen_calls[1].opts.cwd
  end

  describe("with a folder that exists", function()
    for _, case in ipairs(names) do
      it("starts in a static cwd whose folder has " .. case.name .. ", as written", function()
        local dir = root .. "/" .. case.folder
        vim.fn.mkdir(dir, "p")

        assert.are.equal(dir, started_in({ cwd = dir }))
      end)

      it("starts in a cwd_provider result whose folder has " .. case.name .. ", as written", function()
        local dir = root .. "/" .. case.folder
        vim.fn.mkdir(dir, "p")

        assert.are.equal(
          dir,
          started_in({
            cwd_provider = function()
              return dir
            end,
          })
        )
      end)
    end
  end)

  describe("with text that names no folder", function()
    it("expands ~ in a static cwd", function()
      vim.fn.mkdir(root .. "/home/sub", "p")
      vim.env.HOME = root .. "/home"

      assert.are.equal(root .. "/home/sub", started_in({ cwd = "~/sub" }))
    end)

    it("expands $VAR in a static cwd", function()
      vim.fn.mkdir(root .. "/base/sub", "p")
      vim.env.CLAUDECODE_CWD_SPEC_BASE = root .. "/base"

      assert.are.equal(root .. "/base/sub", started_in({ cwd = "$CLAUDECODE_CWD_SPEC_BASE/sub" }))
    end)

    it("expands ~ in a cwd_provider result", function()
      vim.fn.mkdir(root .. "/home/sub", "p")
      vim.env.HOME = root .. "/home"

      assert.are.equal(
        root .. "/home/sub",
        started_in({
          cwd_provider = function()
            return "~/sub"
          end,
        })
      )
    end)

    it("expands $VAR in a cwd_provider result", function()
      vim.fn.mkdir(root .. "/base/sub", "p")
      vim.env.CLAUDECODE_CWD_SPEC_BASE = root .. "/base"

      assert.are.equal(
        root .. "/base/sub",
        started_in({
          cwd_provider = function()
            return "$CLAUDECODE_CWD_SPEC_BASE/sub"
          end,
        })
      )
    end)
  end)

  describe("which setting wins", function()
    local function folder(name)
      local dir = root .. "/" .. name
      vim.fn.mkdir(dir, "p")
      return dir
    end

    it("takes the cwd_provider result over the static cwd", function()
      local from_static, from_provider = folder("static"), folder("provider")

      assert.are.equal(
        from_provider,
        started_in({
          cwd = from_static,
          cwd_provider = function()
            return from_provider
          end,
        })
      )
    end)

    it("takes the static cwd when the cwd_provider returns an empty string", function()
      local from_static = folder("static")

      assert.are.equal(
        from_static,
        started_in({
          cwd = from_static,
          cwd_provider = function()
            return ""
          end,
        })
      )
    end)

    it("takes the static cwd when the cwd_provider raises", function()
      local from_static = folder("static")

      assert.are.equal(
        from_static,
        started_in({
          cwd = from_static,
          cwd_provider = function()
            error("provider failed")
          end,
        })
      )
    end)
  end)
end)

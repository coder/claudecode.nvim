require("tests.busted_setup")

describe("The git root lookup", function()
  local cwd, temp_dir, dir
  local saved = {}
  local git_calls, git_runs

  -- Stands in for vim.fn.systemlist. `outcome` is what git printed and how it ended. A run is a call that did not raise:
  -- the real function starts the process only then.
  local function stub_git(outcome)
    vim.fn.systemlist = function(command)
      git_calls[#git_calls + 1] = command
      git_runs = git_runs + 1
      vim.v.shell_error = outcome.exit_code
      return outcome.lines
    end
  end

  before_each(function()
    package.loaded["claudecode.cwd"] = nil
    cwd = require("claudecode.cwd")
    temp_dir = require("tests.helpers.temp_dir")
    dir = temp_dir.new()
    git_calls, git_runs = {}, 0
    saved.systemlist, saved.shell_error, saved.finddir = vim.fn.systemlist, vim.v.shell_error, vim.fn.finddir
    saved.shellescape = vim.fn.shellescape
  end)

  after_each(function()
    vim.fn.systemlist, vim.v.shell_error, vim.fn.finddir = saved.systemlist, saved.shell_error, saved.finddir
    vim.fn.shellescape = saved.shellescape
    temp_dir.remove(dir)
  end)

  it("runs git rev-parse once and returns the root it printed", function()
    stub_git({ lines = { dir }, exit_code = 0 })

    assert.equals(dir, cwd.git_root(dir))

    assert.equals(1, git_runs, vim.inspect(git_calls))
    assert.same({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, git_calls[1])
  end)

  it("runs git rev-parse once for a folder that is not in a repository, then searches for .git", function()
    stub_git({ lines = { "fatal: not a git repository" }, exit_code = 128 })
    local searched
    vim.fn.finddir = function(name, path)
      searched = { name = name, path = path }
      return ""
    end

    assert.is_nil(cwd.git_root(dir))

    assert.equals(1, git_runs, vim.inspect(git_calls))
    assert.same({ name = ".git", path = dir .. ";" }, searched)
  end)

  it("runs git rev-parse as a shell string, once, when systemlist refuses a list", function()
    vim.fn.shellescape = function(text)
      return "'" .. text .. "'"
    end
    vim.fn.systemlist = function(command)
      git_calls[#git_calls + 1] = command
      if type(command) == "table" then
        error("E475: Invalid argument: expected String")
      end
      git_runs = git_runs + 1
      vim.v.shell_error = 0
      return { dir }
    end

    assert.equals(dir, cwd.git_root(dir))

    assert.equals(1, git_runs, vim.inspect(git_calls))
    assert.equals("string", type(git_calls[#git_calls]))
  end)

  it("does not run git for a folder that does not exist", function()
    stub_git({ lines = { dir }, exit_code = 0 })

    assert.is_nil(cwd.git_root(dir .. "/missing"))

    assert.equals(0, #git_calls)
  end)

  it("runs git rev-parse once for each lookup that resolve makes with git_repo_cwd", function()
    stub_git({ lines = { dir }, exit_code = 0 })

    assert.equals(dir, cwd.resolve({ git_repo_cwd = true }, { file_dir = dir, cwd = dir }))

    assert.equals(1, git_runs, vim.inspect(git_calls))
  end)
end)

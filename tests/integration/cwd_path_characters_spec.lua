if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the git root of a folder whose name holds unusual characters", function()
    pending("needs a real Neovim")
  end)
  return
end

if vim.fn.has("win32") == 1 then
  describe("the git root of a folder whose name holds unusual characters", function()
    pending("these names are not legal on Windows")
  end)
  return
end

-- cwd.git_root finds the repository of a folder, so a repository in a folder with a space, a comma or a quote in its
-- name must be found like any other. `git rev-parse` is the first try. When git cannot run (it is not installed, or
-- not on PATH), a walk up to the nearest `.git` folder answers. Both took the path as a pattern: the walk read it as a
-- list of folders ('path' option syntax), and every lookup passed it to `vim.fn.expand`, which reads `[`, `{`, `*`, `?`,
-- `$` and `\` as patterns or variables.
describe("the git root of a folder whose name holds unusual characters", function()
  local cwd = require("claudecode.cwd")
  local root, empty_bin, saved

  -- Each name is legal in a path on Linux and macOS. The folder is the repository.
  local names = {
    { name = "no unusual character", folder = "repo" },
    { name = "a space", folder = "with space" },
    { name = "a comma", folder = "comma,dir" },
    { name = "a semicolon", folder = "semi;colon" },
    { name = "a single quote", folder = "it's" },
    { name = "double quotes", folder = 'say "hi"' },
    { name = "brackets and braces", folder = "[x] {y}" },
    { name = "parentheses", folder = "(a) (b)" },
    { name = "non-ASCII letters", folder = "ünï-cødé-日本語" },
    { name = "a star and a question mark", folder = "star*mark?" },
    { name = "a percent sign and a hash", folder = "percent%d#hash" },
    { name = "a backslash", folder = "back\\slash" },
    { name = "a dollar sign", folder = "$HOME-like" },
    { name = "a leading tilde", folder = "~tilde" },
  }

  --- Whether a folder above the test folders belongs to a repository, which would answer for a folder that has none.
  local function repository_above(dir)
    while true do
      if vim.fn.isdirectory(dir .. "/.git") == 1 then
        return true
      end
      local parent = vim.fn.fnamemodify(dir, ":h")
      if parent == dir then
        return false
      end
      dir = parent
    end
  end

  local function realpath(path)
    return vim.loop.fs_realpath(path) or path
  end

  --- Makes `<root>/<mode>/<folder>` with a `sub/deeper` folder in it.
  ---@param make_repo fun(repo: string) Makes the folder a repository
  local function repo_in(mode, folder, make_repo)
    local repo = root .. "/" .. mode .. "/" .. folder
    vim.fn.mkdir(repo .. "/sub/deeper", "p")
    make_repo(repo)
    return repo
  end

  before_each(function()
    root = vim.fn.tempname()
    empty_bin = root .. "/empty-bin"
    vim.fn.mkdir(empty_bin, "p")
    saved = { path = vim.env.PATH, shell = vim.o.shell }
  end)

  after_each(function()
    vim.env.PATH, vim.o.shell = saved.path, saved.shell
    vim.fn.delete(root, "rf")
  end)

  --- Runs `fn` with git off PATH, as on a host that has no git. The shell keeps its absolute path, so a command that
  --- names git ends with "not found" and shell_error 127, and a list command raises E475, as they do there.
  local function without_git(fn)
    local shell = vim.fn.exepath("sh")
    assert.is_true(shell ~= "", "the test needs sh")
    vim.o.shell, vim.env.PATH = shell, empty_bin
    local ok, result = pcall(fn)
    vim.o.shell, vim.env.PATH = saved.shell, saved.path
    assert(ok, result)
    return result
  end

  describe("when git cannot run", function()
    it("really cannot run git here", function()
      without_git(function()
        assert.equals(0, vim.fn.executable("git"))
      end)
    end)

    for _, case in ipairs(names) do
      it("finds a repository whose folder has " .. case.name, function()
        local repo = repo_in("no-git", case.folder, function(path)
          vim.fn.mkdir(path .. "/.git", "p")
        end)

        local from_root = without_git(function()
          return cwd.git_root(repo)
        end)
        local from_subfolder = without_git(function()
          return cwd.git_root(repo .. "/sub/deeper")
        end)

        assert.equals(realpath(repo), from_root and realpath(from_root), "from the repository folder")
        assert.equals(realpath(repo), from_subfolder and realpath(from_subfolder), "from a folder inside it")
        -- The answer is the folder itself, not another spelling of it.
        assert.is_nil(from_root and from_root:find("/$"), "no trailing slash")
      end)
    end

    -- A folder above the test folders can hold a repository, for example a TMPDIR inside a checkout.
    local make_non_repo_test = repository_above(vim.fn.fnamemodify(vim.fn.tempname(), ":h")) and pending or it
    make_non_repo_test("finds no repository for a folder that has none, whatever its name", function()
      for _, case in ipairs(names) do
        local folder = root .. "/non-repo/" .. case.folder
        vim.fn.mkdir(folder, "p")

        local found = without_git(function()
          return cwd.git_root(folder)
        end)

        assert.is_nil(found, "a non-repository folder with " .. case.name)
      end
    end)
  end)

  describe("when git runs", function()
    if vim.fn.executable("git") ~= 1 then
      pending("needs git")
      return
    end

    for _, case in ipairs(names) do
      it("finds a repository whose folder has " .. case.name, function()
        local repo = repo_in("git", case.folder, function(path)
          vim.fn.system({ "git", "init", "-q", path })
          assert.equals(0, vim.v.shell_error, "git init")
        end)

        local from_root = cwd.git_root(repo)
        local from_subfolder = cwd.git_root(repo .. "/sub/deeper")

        assert.equals(realpath(repo), from_root and realpath(from_root), "from the repository folder")
        assert.equals(realpath(repo), from_subfolder and realpath(from_subfolder), "from a folder inside it")
        -- The answer is the folder itself, not another spelling of it.
        assert.is_nil(from_root and from_root:find("/$"), "no trailing slash")
      end)
    end
  end)

  describe("a start folder given relative to the current folder", function()
    it("finds the repository above the current folder, when git cannot run", function()
      local repo = repo_in("relative", "my repo", function(path)
        vim.fn.mkdir(path .. "/.git", "p")
      end)
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(repo .. "/sub"))

      local from_dot = without_git(function()
        return cwd.git_root(".")
      end)
      local from_child = without_git(function()
        return cwd.git_root("deeper")
      end)
      vim.cmd("cd " .. vim.fn.fnameescape(saved_cwd))

      assert.equals(realpath(repo), from_dot and realpath(from_dot), "from .")
      assert.equals(realpath(repo), from_child and realpath(from_child), "from a folder inside the current one")
    end)
    it("goes up from a start folder that ends in .., when git cannot run", function()
      local outer = repo_in("dotdot", "outer", function(path)
        vim.fn.mkdir(path .. "/.git", "p")
      end)
      vim.fn.mkdir(outer .. "/a/b/.git", "p")
      local saved_cwd = vim.fn.getcwd()
      vim.cmd("cd " .. vim.fn.fnameescape(outer .. "/a/b"))

      local from_parent = without_git(function()
        return cwd.git_root("..")
      end)
      vim.cmd("cd " .. vim.fn.fnameescape(saved_cwd))

      -- ".." is outer/a, which has no .git folder: its repository is outer, not outer/a/b below it.
      assert.equals(realpath(outer), from_parent and realpath(from_parent))
    end)
  end)

  -- The next two blocks test `cwd.resolve`, not the terminal. `terminal.lua:build_config` does not call it: it expands
  -- a static `cwd` and a `cwd_provider` result with `vim.fn.expand` itself, so these cases say nothing about what the
  -- terminal does with a folder name that holds `$` or a backslash.
  describe("cwd.resolve with git_repo_cwd", function()
    it("returns the repository of a file folder whose name has a space and a bracket, when git cannot run", function()
      local repo = repo_in("resolve", "my [repo]", function(path)
        vim.fn.mkdir(path .. "/.git", "p")
      end)

      local resolved = without_git(function()
        return cwd.resolve({ git_repo_cwd = true }, { file_dir = repo .. "/sub", cwd = repo })
      end)

      assert.equals(realpath(repo), resolved and realpath(resolved))
    end)
  end)

  describe("cwd.resolve with a folder given as a setting", function()
    it("still expands ~ and $VAR when the text is not a folder", function()
      local repo = repo_in("setting", "proj", function(path)
        vim.fn.mkdir(path .. "/.git", "p")
      end)
      local saved_home, saved_var = vim.env.HOME, vim.env.CLAUDECODE_TEST_ROOT
      vim.env.HOME, vim.env.CLAUDECODE_TEST_ROOT = root .. "/setting", root .. "/setting"

      local tilde = cwd.resolve({ cwd = "~/proj" }, {})
      local variable = cwd.resolve({ cwd = "$CLAUDECODE_TEST_ROOT/proj" }, {})
      vim.env.HOME, vim.env.CLAUDECODE_TEST_ROOT = saved_home, saved_var

      assert.equals(realpath(repo), tilde and realpath(tilde))
      assert.equals(realpath(repo), variable and realpath(variable))
    end)

    it("takes a static cwd with brackets and a star as the folder it names", function()
      local repo = repo_in("setting", "[a] {b} *", function(path)
        vim.fn.mkdir(path .. "/.git", "p")
      end)

      local resolved = cwd.resolve({ cwd = repo }, {})

      assert.equals(repo, resolved)
    end)
  end)
end)

require("tests.busted_setup")

describe(".luacov", function()
  local function copy(list)
    local result = {}
    for key, value in pairs(list) do
      result[key] = value
    end
    return result
  end

  ---Loads .luacov with stubs for the shell and for TMPDIR, then gives it to a second copy of luacov's runner, so
  ---`file_included` answers as luacov does, including the patterns that the `modules` option adds.
  ---@param typed string what `pwd` prints
  ---@param resolved string what `pwd -P` prints
  ---@param tmpdir? string the value of TMPDIR, nil when it is unset
  ---@return table runner
  local function load_runner(typed, resolved, tmpdir)
    local chunk = assert(loadfile(".luacov"))
    local outputs = { ["pwd"] = typed, ["pwd -P"] = resolved }
    local env = setmetatable({
      io = {
        popen = function(command)
          local line = assert(outputs[command], "unexpected command: " .. command)
          return {
            read = function(_, format)
              assert(format == nil or format == "*l" or format == "l", "reads one line, not " .. tostring(format))
              return line
            end,
            close = function()
              return true
            end,
          }
        end,
      },
      os = setmetatable({
        getenv = function(name)
          assert(name == "TMPDIR", "unexpected variable: " .. tostring(name))
          return tmpdir
        end,
      }, { __index = os }),
    }, { __index = _G })
    setfenv(chunk, env)

    local configuration = {}
    for key, value in pairs(chunk()) do
      configuration[key] = type(value) == "table" and copy(value) or value
    end
    configuration.exclude = configuration.exclude or {}

    local runner = assert(loadfile(assert(package.searchpath("luacov.runner", package.path))))()
    runner.load_config(configuration)
    return runner
  end

  ---@param runner table
  ---@param root string the checkout folder the paths are under
  local function assert_plugin_only(runner, root)
    assert.is_true(runner.file_included(root .. "/plugin/claudecode.lua"))
    assert.is_true(runner.file_included(root .. "/lua/claudecode/init.lua"))
    assert.is_true(runner.file_included(root .. "/lua/claudecode/server/client.lua"))
    assert.is_true(runner.file_included(root .. "/lua/claudecode/a/b/c.lua"))
    assert.is_false(runner.file_included(root .. "/tests/busted_setup.lua"))
    assert.is_false(runner.file_included(root .. "/tests/mocks/vim.lua"))
    assert.is_false(runner.file_included(root .. "/fixtures/nvim/init.lua"))
    assert.is_false(runner.file_included(root .. "/.luarocks/share/lua/5.1/busted/init.lua"))
    assert.is_false(runner.file_included(root .. "/plugins/claudecode.lua"))
    assert.is_false(runner.file_included(root .. "/lua/claudecode-extra/init.lua"))
  end

  it("keeps plugin files and drops tests and rocks of a checkout under a folder ending in plugin", function()
    local root = "/w/xplugin/claudecode.nvim"
    local runner = load_runner(root, root)

    assert_plugin_only(runner, root)
    assert.is_true(runner.file_included("plugin/claudecode.lua"))
    assert.is_true(runner.file_included("lua/claudecode/init.lua"))
    assert.is_true(runner.file_included("lua/claudecode/a/b/c.lua"))
    assert.is_false(runner.file_included("tests/unit/diff_spec.lua"))
    assert.is_false(runner.file_included("plugins/claudecode.lua"))
    assert.is_false(runner.file_included("lua/claudecode-extra/init.lua"))
  end)

  it("keeps plugin files by the folder as typed and with symlinks resolved", function()
    local typed = "/home/u/link"
    local resolved = "/data/real/claudecode.nvim"
    local runner = load_runner(typed, resolved)

    assert_plugin_only(runner, typed)
    assert_plugin_only(runner, resolved)
  end)

  it("keeps plugin files of a checkout in CI's folder", function()
    local root = "/home/runner/work/claudecode.nvim/claudecode.nvim"

    assert_plugin_only(load_runner(root, root), root)
  end)

  it("takes a folder name's pattern characters literally", function()
    local root = "/w/my-check.out+1%/claude-code.nvim"
    local runner = load_runner(root, root)

    assert_plugin_only(runner, root)
    assert.is_false(runner.file_included("/w/my-checkXout+1%/claude-code.nvim/plugin/claudecode.lua"))
    assert.is_false(runner.file_included("/w/my-check.out+1%/claude-code.nvimX/plugin/claudecode.lua"))
  end)

  it("does not match a path that has the checkout folder somewhere in the middle", function()
    local root = "/home/u/claudecode.nvim"
    local runner = load_runner(root, root)

    assert.is_false(runner.file_included("/mnt" .. root .. "/plugin/claudecode.lua"))
  end)

  describe("a copy of init.lua that a spec runs from a temp folder", function()
    local function copy_path(tmpdir)
      return tmpdir .. "/claudecode.AbC123/lua/claudecode/init.lua"
    end

    it("is not counted when TMPDIR is unset", function()
      local runner = load_runner("/w/claudecode.nvim", "/w/claudecode.nvim")

      assert.is_false(runner.file_included(copy_path("/tmp")))
    end)

    it("is not counted when TMPDIR ends in a slash", function()
      local runner = load_runner("/w/claudecode.nvim", "/w/claudecode.nvim", "/var/folders/ab/T/")

      assert.is_false(runner.file_included(copy_path("/var/folders/ab/T")))
    end)

    it("is not counted when TMPDIR has pattern characters, and a similar folder is not skipped", function()
      local runner = load_runner("/w/claudecode.nvim", "/w/claudecode.nvim", "/my-tmp.dir+1%")

      assert.is_false(runner.file_included(copy_path("/my-tmp.dir+1%")))
      assert.is_true(runner.file_included("/w/claudecode.nvim/lua/claudecode/init.lua"))
    end)

    it("is not mistaken for a checkout that sits in the temp folder under a name like claudecode.nvim", function()
      local root = "/tmp/claudecode.nvim"

      assert_plugin_only(load_runner(root, root), root)
    end)
  end)
end)

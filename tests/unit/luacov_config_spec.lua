require("tests.busted_setup")

describe(".luacov include patterns", function()
  ---@param typed string what `pwd` prints
  ---@param resolved string what `pwd -P` prints
  ---@return table config
  local function load_config(typed, resolved)
    local chunk = assert(loadfile(".luacov"))
    local outputs = { ["pwd"] = typed, ["pwd -P"] = resolved }
    local env = setmetatable({
      io = {
        popen = function(command)
          local line = assert(outputs[command], "unexpected command: " .. command)
          return {
            read = function()
              return line
            end,
            close = function()
              return true
            end,
          }
        end,
      },
    }, { __index = _G })
    setfenv(chunk, env)
    return chunk()
  end

  -- luacov strips ".lua" from the path and calls string.match with each include pattern (runner.file_included).
  local function included(config, path)
    local name = path:gsub("%.lua$", "")
    for _, pattern in ipairs(config.include) do
      if name:match(pattern) then
        return true
      end
    end
    return false
  end

  ---@param config table
  ---@param root string the checkout folder the paths are under
  local function assert_plugin_only(config, root)
    assert.is_true(included(config, root .. "/plugin/claudecode.lua"))
    assert.is_true(included(config, root .. "/lua/claudecode/init.lua"))
    assert.is_true(included(config, root .. "/lua/claudecode/server/client.lua"))
    assert.is_false(included(config, root .. "/tests/busted_setup.lua"))
    assert.is_false(included(config, root .. "/tests/mocks/vim.lua"))
    assert.is_false(included(config, root .. "/fixtures/nvim/init.lua"))
    assert.is_false(included(config, root .. "/.luarocks/share/lua/5.1/busted/init.lua"))
  end

  it("keeps plugin files and drops tests and rocks of a checkout under a folder ending in plugin", function()
    local root = "/w/xplugin/claudecode.nvim"
    local config = load_config(root, root)

    assert_plugin_only(config, root)
    assert.is_true(included(config, "plugin/claudecode.lua"))
    assert.is_true(included(config, "lua/claudecode/init.lua"))
    assert.is_false(included(config, "tests/unit/diff_spec.lua"))
    assert.is_false(included(config, "fixtures/nvim/lua/claudecode/init.lua"))
  end)

  it("keeps plugin files by the folder as typed and with symlinks resolved", function()
    local typed = "/home/u/link"
    local resolved = "/data/real/claudecode.nvim"
    local config = load_config(typed, resolved)

    assert_plugin_only(config, typed)
    assert_plugin_only(config, resolved)
  end)

  it("keeps plugin files of a checkout in CI's folder", function()
    local root = "/home/runner/work/claudecode.nvim/claudecode.nvim"

    assert_plugin_only(load_config(root, root), root)
  end)

  it("takes a folder name's pattern characters literally", function()
    local root = "/w/my-check.out+1%/claude-code.nvim"
    local config = load_config(root, root)

    assert_plugin_only(config, root)
    assert.is_false(included(config, "/w/my-checkXout+1%/claude-code.nvim/plugin/claudecode.lua"))
    assert.is_false(included(config, "/w/my-check.out+1%/claude-code.nvimX/plugin/claudecode.lua"))
  end)

  it("does not match a path that has the checkout folder somewhere in the middle", function()
    local root = "/home/u/claudecode.nvim"
    local config = load_config(root, root)

    assert.is_false(included(config, "/mnt" .. root .. "/plugin/claudecode.lua"))
    assert.is_false(included(config, "/mnt" .. root .. "/lua/claudecode/init.lua"))
  end)
end)

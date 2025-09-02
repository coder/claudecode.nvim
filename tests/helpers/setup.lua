-- Test environment setup

-- This function sets up the test environment
return function()
  -- Create mock vim API if we're running tests outside of Neovim
  if not vim then
    -- luacheck: ignore
    _G.vim = require("tests.mocks.vim")
  end

  -- Setup test globals
  _G.assert = require("luassert")
  _G.stub = require("luassert.stub")
  _G.spy = require("luassert.spy")
  _G.mock = require("luassert.mock")

  -- Helper function to verify a test passes
  _G.it = function(desc, fn)
    local ok, err = pcall(fn)
    if not ok then
      print("FAIL: " .. desc)
      print(err)
      error("Test failed: " .. desc)
    else
      print("PASS: " .. desc)
    end
  end

  -- Helper function to describe a test group
  _G.describe = function(desc, fn)
    print("\n==== " .. desc .. " ====")
    fn()
  end

  -- Load the plugin under test
  package.loaded["claudecode"] = nil

  -- Return true to indicate setup was successful
  return true
end

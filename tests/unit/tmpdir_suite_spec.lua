require("tests.busted_setup")

local temp_dir = require("tests.helpers.temp_dir")
local quote = temp_dir.quote

describe("the suite under an odd TMPDIR", function()
  local root = require("pl.path").abspath(debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/unit/[^/]+$")
  local outer

  setup(function()
    outer = temp_dir.new()
  end)

  teardown(function()
    temp_dir.remove(outer)
  end)

  ---@param cwd string
  ---@param tmpdir string
  ---@param spec_from_root string
  ---@param filter string|nil
  ---@return string
  local function run_child(cwd, tmpdir, spec_from_root, filter)
    local command = string.format(
      "cd %s && mkdir -p %s && TMPDIR=%s %s %s%s 2>&1; echo status=$?",
      quote(cwd),
      quote(tmpdir),
      quote(tmpdir),
      quote(root .. "/.luarocks/bin/busted"),
      filter and ("--filter=" .. quote(filter) .. " ") or "",
      quote(root .. "/" .. spec_from_root)
    )
    local pipe = assert(io.popen(command))
    local output = pipe:read("*a")
    pipe:close()
    return output
  end

  it("runs the lockfile spec with a % in TMPDIR", function()
    local output = run_child(outer, outer .. "/50%-off", "tests/lockfile_test.lua")

    assert.is_truthy(output:find("status=0", 1, true), output)
    assert.is_truthy(output:find("16 successes", 1, true), output)
  end)

  it("runs a test of the integration runner spec with a relative TMPDIR", function()
    local output = run_child(outer, "reltmp", "tests/unit/integration_runner_spec.lua", "passes when every file prints")

    assert.is_truthy(output:find("status=0", 1, true), output)
    assert.is_truthy(output:find("1 success", 1, true), output)
  end)
end)

--- scripts/run_integration_tests_individually.sh runs each tests/integration spec in its own Neovim, and CI's integration
--- jobs trust its exit status. The spec below runs the real script in a scratch tree, with stub `timeout` and `nvim`
--- programs that print what plenary prints and exit with a chosen status, so it needs no Neovim and waits for no timeout.
require("tests.busted_setup")

local temp_dir = require("tests.helpers.temp_dir")
local quote = temp_dir.quote

-- `timeout 30s nvim ...` runs `nvim ...`. The stub nvim finds the spec in the `test_file('<spec>')` argument, records
-- its name, then plays back that spec's canned output and exit status.
local STUB_TIMEOUT = { "#!/bin/sh", "shift", 'exec "$@"' }
local STUB_NVIM = {
  "#!/bin/sh",
  'for arg in "$@"; do',
  '  case "$arg" in',
  '    *"test_file(\'"*) spec=${arg#*"test_file(\'"}; spec=${spec%%"\'"*} ;;',
  "  esac",
  "done",
  "name=${spec##*/}",
  'echo "$name" >> "$STUB_DIR/ran"',
  'cat "$STUB_DIR/$name.out"',
  'exit "$(cat "$STUB_DIR/$name.exit")"',
}

-- Plenary prints these three lines, in colour, when a file's specs have all finished.
---@param success integer
---@param failed integer
---@param errors integer
---@return string[]
local function summary(success, failed, errors)
  return {
    "\27[32mSuccess: \27[0m\t" .. success,
    "\27[31mFailed : \27[0m\t" .. failed,
    "\27[31mErrors : \27[0m\t" .. errors,
  }
end

-- What plenary has printed when a spec hangs in its second test: the first test's result, and no summary.
local function before_summary(spec)
  return { "Testing: \t/repo/tests/integration/" .. spec, "\27[32mSuccess\27[0m\t||\tfirst test" }
end

describe("scripts/run_integration_tests_individually.sh", function()
  -- The repo root, from this file's path, so the spec runs from any directory.
  local root = require("pl.path").abspath(debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/unit/[^/]+$")
  local script = root .. "/scripts/run_integration_tests_individually.sh"
  local dir

  ---@param path string
  ---@param lines string[]
  ---@param executable boolean|nil
  local function write(path, lines, executable)
    local file = assert(io.open(path, "w"))
    file:write(table.concat(lines, "\n"), "\n")
    file:close()
    if executable then
      assert(os.execute("chmod +x " .. quote(path)) ~= nil)
    end
  end

  before_each(function()
    dir = temp_dir.new()
    assert(
      os.execute(
        "mkdir " .. quote(dir .. "/bin") .. " " .. quote(dir .. "/tests") .. " " .. quote(dir .. "/tests/integration")
      ) ~= nil
    )
    write(dir .. "/bin/timeout", STUB_TIMEOUT, true)
    write(dir .. "/bin/nvim", STUB_NVIM, true)
  end)

  after_each(function()
    temp_dir.remove(dir)
  end)

  ---@param specs { name: string, exit: integer, output: string[] }[] The integration specs, in the order they run
  ---@return string status The exit status of the script
  ---@return string output What the script printed
  ---@return string[] ran The names of the specs the stub nvim ran, in order
  local function run_script(specs)
    for _, spec in ipairs(specs) do
      write(dir .. "/tests/integration/" .. spec.name, {})
      write(dir .. "/" .. spec.name .. ".out", spec.output)
      write(dir .. "/" .. spec.name .. ".exit", { tostring(spec.exit) })
    end
    local command = "cd " .. quote(dir) .. " && PATH=" .. quote(dir .. "/bin") .. ':"$PATH" STUB_DIR=' .. quote(dir)
    local pipe = assert(io.popen(command .. " " .. quote(script) .. " 2>&1; echo status=$?"))
    local output = pipe:read("*a")
    pipe:close()
    local ran = {}
    local log = io.open(dir .. "/ran")
    if log then
      for name in log:lines() do
        table.insert(ran, name)
      end
      log:close()
    end
    return output:match("status=(%d+)"), output, ran
  end

  it("passes when every file prints a clean summary and exits 0", function()
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(3, 0, 0) },
      { name = "b_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("0", status, output)
    assert.is_truthy(output:find("All integration tests passed!", 1, true), output)
  end)

  it("fails a file that hit the timeout before busted printed its summary", function()
    local status, output = run_script({
      { name = "hang_spec.lua", exit = 124, output = before_summary("hang_spec.lua") },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("Failed test files:\n  - hang_spec.lua", 1, true), output)
  end)

  it("fails a file that was killed by SIGTERM before busted printed its summary", function()
    local status, output = run_script({
      { name = "killed_spec.lua", exit = 143, output = before_summary("killed_spec.lua") },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("Failed test files:\n  - killed_spec.lua", 1, true), output)
  end)

  it("fails a file that hit the timeout and printed no output at all", function()
    local status, output = run_script({
      { name = "silent_spec.lua", exit = 124, output = {} },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("Failed test files:\n  - silent_spec.lua", 1, true), output)
  end)

  it("still fails a file whose summary counts a failure, whatever the exit status", function()
    local status, output = run_script({
      { name = "failing_spec.lua", exit = 124, output = summary(2, 1, 0) },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("Failed test files:\n  - failing_spec.lua", 1, true), output)
  end)

  it("lets a file pass whose specs all finished and only nvim's exit hung", function()
    local status, output = run_script({
      { name = "slow_exit_spec.lua", exit = 124, output = summary(4, 0, 0) },
    })

    assert.are.equal("0", status, output)
  end)

  it("runs the files after a hung one and lists only the hung one", function()
    local status, output, ran = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
      { name = "hang_spec.lua", exit = 124, output = before_summary("hang_spec.lua") },
      { name = "z_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("1", status, output)
    assert.are.same({ "a_spec.lua", "hang_spec.lua", "z_spec.lua" }, ran)
    assert.is_truthy(output:find("Failed test files:\n  - hang_spec.lua\n", 1, true), output)
  end)
end)

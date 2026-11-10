require("tests.busted_setup")

local temp_dir = require("tests.helpers.temp_dir")
local quote = temp_dir.quote

local STUB_TIMEOUT = {
  "#!/bin/sh",
  'for arg in "$@"; do',
  '  case "$arg" in',
  "    [0-9]*s) arg=1s ;;",
  "  esac",
  '  set -- "$@" "$arg"',
  "  shift",
  "done",
  'exec "$REAL_TIMEOUT" "$@"',
}
local STUB_NVIM = {
  "#!/bin/sh",
  'for arg in "$@"; do',
  '  case "$arg" in',
  '    *"test_file(\'"*) spec=${arg#*"test_file(\'"}; spec=${spec%%"\'"*} ;;',
  "  esac",
  "done",
  "name=${spec##*/}",
  'echo "$name" >> "$STUB_DIR/ran"',
  'if [ -f "$STUB_DIR/$name.ignore_term" ]; then',
  "  trap '' TERM",
  "  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sleep 1; done",
  "fi",
  'if [ -f "$STUB_DIR/$name.orphan" ]; then',
  "  sh -c 'trap \"\" TERM; exec sleep 60' > /dev/null 2>&1 &",
  '  echo $! > "$STUB_DIR/$name.orphan.pid"',
  "fi",
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

local function hung_output(spec)
  return { "Testing: \t/repo/tests/integration/" .. spec, "\27[32mSuccess\27[0m\t||\tfirst test" }
end

---@param command string
local function shell(command)
  local status = os.execute(command)
  assert(status == 0 or status == true, "failed: " .. command)
end

local timeout_pipe = assert(io.popen("command -v timeout 2> /dev/null"))
local real_timeout = timeout_pipe:read("*l")
timeout_pipe:close()
if not real_timeout or real_timeout == "" then
  describe("scripts/run_integration_tests_individually.sh", function()
    pending("needs GNU timeout")
  end)
  return
end

describe("scripts/run_integration_tests_individually.sh", function()
  local root = require("pl.path").abspath(debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/unit/[^/]+$")
  local script = root .. "/scripts/run_integration_tests_individually.sh"
  local dir
  local orphan_pid

  ---@param path string
  ---@param lines string[]
  ---@param executable boolean|nil
  local function write(path, lines, executable)
    local file = assert(io.open(path, "w"))
    file:write(table.concat(lines, "\n"), "\n")
    file:close()
    if executable then
      shell("chmod +x " .. quote(path))
    end
  end

  ---@param pid string
  ---@return boolean running A zombie that init has not reaped yet does not count
  local function is_running(pid)
    local pipe = assert(io.popen("ps -o stat= -p " .. pid .. " 2> /dev/null"))
    local stat = pipe:read("*a")
    pipe:close()
    return stat:match("%S") ~= nil and stat:match("^%s*Z") == nil
  end

  ---@param pid string
  local function wait_until_stopped(pid)
    local deadline = os.time() + 3
    while is_running(pid) and os.time() < deadline do
      os.execute("sleep 0.1")
    end
  end

  before_each(function()
    dir = temp_dir.new()
    orphan_pid = nil
    shell("mkdir -p " .. quote(dir .. "/bin") .. " " .. quote(dir .. "/tests/integration"))
    write(dir .. "/bin/nvim", STUB_NVIM, true)
    write(dir .. "/bin/timeout", STUB_TIMEOUT, true)
  end)

  after_each(function()
    if orphan_pid and is_running(orphan_pid) then
      shell("kill -KILL " .. orphan_pid)
    end
    temp_dir.remove(dir)
  end)

  ---@param specs { name: string, exit: integer, output: string[], orphan: boolean|nil, ignore_term: boolean|nil }[]
  ---@return string status
  ---@return string output
  ---@return string[] ran
  local function run_script(specs)
    for _, spec in ipairs(specs) do
      write(dir .. "/tests/integration/" .. spec.name, {})
      write(dir .. "/" .. spec.name .. ".out", spec.output)
      write(dir .. "/" .. spec.name .. ".exit", { tostring(spec.exit) })
      if spec.orphan then
        write(dir .. "/" .. spec.name .. ".orphan", {})
      end
      if spec.ignore_term then
        write(dir .. "/" .. spec.name .. ".ignore_term", {})
      end
    end
    local command = "cd "
      .. quote(dir)
      .. " && PATH="
      .. quote(dir .. "/bin")
      .. ':"$PATH" STUB_DIR='
      .. quote(dir)
      .. " REAL_TIMEOUT="
      .. quote(real_timeout)
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
    assert.is_nil(output:find("TIMEOUT", 1, true), output)
  end)

  it("runs command_args_spec.lua like every other file", function()
    local status, output, ran = run_script({
      { name = "command_args_spec.lua", exit = 0, output = summary(8, 0, 0) },
    })

    assert.are.equal("0", status, output)
    assert.are.same({ "command_args_spec.lua" }, ran)
    assert.is_nil(output:find("Skipping", 1, true), output)
  end)

  it("fails a file that hit the timeout while its specs ran", function()
    local status, output = run_script({
      { name = "hang_spec.lua", exit = 124, output = hung_output("hang_spec.lua") },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("TIMEOUT: hang_spec.lua was stopped (exit 124)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - hang_spec.lua", 1, true), output)
  end)

  it("fails a file that was killed by SIGTERM while its specs ran", function()
    local status, output = run_script({
      { name = "killed_spec.lua", exit = 143, output = hung_output("killed_spec.lua") },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("TIMEOUT: killed_spec.lua was stopped (exit 143)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - killed_spec.lua", 1, true), output)
  end)

  it("fails a file that hit the timeout and printed no output at all", function()
    local status, output = run_script({
      { name = "silent_spec.lua", exit = 124, output = {} },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("TIMEOUT: silent_spec.lua was stopped (exit 124)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - silent_spec.lua", 1, true), output)
  end)

  it("fails a file whose specs all passed but whose nvim did not exit", function()
    local status, output = run_script({
      { name = "slow_exit_spec.lua", exit = 124, output = summary(4, 0, 0) },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("TIMEOUT: slow_exit_spec.lua was stopped (exit 124)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - slow_exit_spec.lua", 1, true), output)
  end)

  it("fails a file whose summary counts a failure, without a TIMEOUT line", function()
    local status, output = run_script({
      { name = "failing_spec.lua", exit = 1, output = summary(2, 1, 0) },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("Failed test files:\n  - failing_spec.lua", 1, true), output)
    assert.is_nil(output:find("TIMEOUT", 1, true), output)
  end)

  it("fails a file whose nvim crashed before any summary, without a TIMEOUT line", function()
    local status, output = run_script({
      { name = "crash_spec.lua", exit = 1, output = hung_output("crash_spec.lua") },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("Failed test files:\n  - crash_spec.lua", 1, true), output)
    assert.is_nil(output:find("TIMEOUT", 1, true), output)
  end)

  it("kills an nvim that ignores SIGTERM", function()
    local status, output = run_script({
      { name = "stuck_spec.lua", exit = 0, output = hung_output("stuck_spec.lua"), ignore_term = true },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("TIMEOUT: stuck_spec.lua was stopped (exit 137)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - stuck_spec.lua", 1, true), output)
  end)

  it("kills what a timed-out file leaves running", function()
    local status, output = run_script({
      { name = "spin_spec.lua", exit = 124, output = hung_output("spin_spec.lua"), orphan = true },
    })
    local pid_file = assert(io.open(dir .. "/spin_spec.lua.orphan.pid"))
    orphan_pid = pid_file:read("*l")
    pid_file:close()

    assert.are.equal("1", status, output)
    wait_until_stopped(orphan_pid)
    assert.is_false(is_running(orphan_pid), "the process the file left running was killed")
  end)

  it("runs the files after a hung one and lists only the hung one", function()
    local status, output, ran = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
      { name = "hang_spec.lua", exit = 124, output = hung_output("hang_spec.lua") },
      { name = "z_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("1", status, output)
    assert.are.same({ "a_spec.lua", "hang_spec.lua", "z_spec.lua" }, ran)
    assert.is_truthy(output:find("Failed test files:\n  - hang_spec.lua\n", 1, true), output)
  end)
end)

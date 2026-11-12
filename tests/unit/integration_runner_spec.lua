require("tests.busted_setup")

local temp_dir = require("tests.helpers.temp_dir")
local quote = temp_dir.quote

local SPEC_NAME = {
  'for arg in "$@"; do',
  '  case "$arg" in',
  '    *"test_file(\'"*) spec=${arg#*"test_file(\'"}; spec=${spec%%"\'"*} ;;',
  "  esac",
  "done",
  "name=${spec##*/}",
}

---@param ... string[]
---@return string[]
local function concat(...)
  local joined = {}
  for _, lines in ipairs({ ... }) do
    for _, line in ipairs(lines) do
      table.insert(joined, line)
    end
  end
  return joined
end

local STUB_TIMEOUT = concat({ "#!/bin/sh" }, SPEC_NAME, {
  'if [ -f "$STUB_DIR/$name.ignore_term" ]; then',
  "  pid=$$",
  '  (while kill -0 "$pid"; do',
  '    if [ -f "$STUB_DIR/$name.ready" ]; then kill -TERM "$pid"; break; fi',
  "    sleep 0.05",
  "  done) > /dev/null 2>&1 &",
  '  echo $! > "$STUB_DIR/$name.helper.pid"',
  '  if [ "$1" = -k ]; then',
  "    shift 2",
  '    set -- -k 1s "$@"',
  "  fi",
  "fi",
  'if [ -f "$STUB_DIR/$name.window" ]; then : > "$STUB_DIR/$name.timeout_started"; sleep 1; fi',
  'echo "$1 $2 $3" >> "$STUB_DIR/timeout_args"',
  'exec "$REAL_TIMEOUT" "$@"',
})
local STUB_NVIM = concat({ "#!/bin/sh" }, SPEC_NAME, {
  'echo "$name" >> "$STUB_DIR/ran"',
  'echo "$*" >> "$STUB_DIR/nvim_args"',
  'if [ -f "$STUB_DIR/$name.sleep" ]; then',
  '  if [ -f "$STUB_DIR/$name.deaf_to_term" ]; then trap "" TERM; fi',
  '  : > "$STUB_DIR/$name.started"',
  '  (sleep 2; mkdir -p "$XDG_STATE_HOME/nvim" && : > "$XDG_STATE_HOME/nvim/shada") &',
  "  wait",
  '  : > "$STUB_DIR/$name.ended"',
  "fi",
  "folders=missing",
  'if [ -d "$XDG_STATE_HOME" ] && [ -d "$XDG_CONFIG_HOME" ]; then folders=present; fi',
  'printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "${VIMINIT-unset}" "${CLAUDECODE_MINIMAL_INIT-unset}" \\',
  '  "${XDG_STATE_HOME-unset}" "${XDG_CONFIG_HOME-unset}" "$folders" "${XDG_DATA_HOME-unset}" >> "$STUB_DIR/env_seen"',
  'if [ -f "$STUB_DIR/$name.ignore_term" ]; then',
  "  trap '' TERM",
  '  : > "$STUB_DIR/$name.ready"',
  "  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sleep 1; done",
  "fi",
  'if [ -f "$STUB_DIR/$name.orphan" ]; then',
  "  sh -c 'trap \"\" TERM; exec sleep 60' > /dev/null 2>&1 &",
  '  echo $! > "$STUB_DIR/$name.orphan.pid"',
  "fi",
  'cat "$STUB_DIR/$name.out"',
  'exit "$(cat "$STUB_DIR/$name.exit")"',
})

-- Plenary prints these three lines, in colour, when a file's specs have all finished.
---@param success integer|string
---@param failed integer|string
---@param errors integer|string
---@return string[]
local function summary(success, failed, errors)
  return {
    "\27[32mSuccess: \27[0m\t" .. success,
    "\27[31mFailed : \27[0m\t" .. failed,
    "\27[31mErrors : \27[0m\t" .. errors,
  }
end

---@param lines string[]
---@param index integer
---@return string[]
local function without(lines, index)
  local kept = {}
  for position, line in ipairs(lines) do
    if position ~= index then
      table.insert(kept, line)
    end
  end
  return kept
end

local function hung_output(spec)
  return { "Testing: \t/repo/tests/integration/" .. spec, "\27[32mSuccess\27[0m\t||\tfirst test" }
end

local ROW_COLOR = { Success = 32, Fail = 31, Pending = 33 }

-- Plenary prints one of these rows, in colour, for each test it ran. The runner reads none of them.
---@param kind "Success"|"Fail"|"Pending"
---@param description string
---@return string
local function row(kind, description)
  return "\27[" .. ROW_COLOR[kind] .. "m" .. kind .. "\27[0m\t||\t" .. description
end

---@param command string
local function shell(command)
  local status = os.execute(command)
  assert(status == 0 or status == true, "failed: " .. command)
end

-- In some locales a bash regex bracket range such as [0-9] also matches digits like the fullwidth １.
---@return string|nil locale A common locale name in which it does, or nil when the host has none
local function find_wide_digit_locale()
  for _, name in ipairs({ "en_US.UTF-8", "en_US.utf8", "en_GB.UTF-8", "en_GB.utf8" }) do
    local pipe =
      assert(io.popen("LC_ALL=" .. name .. " /bin/bash -c '[[ １ =~ ^[0-9]$ ]]' 2> /dev/null && echo matched"))
    local answer = pipe:read("*a")
    pipe:close()
    if answer:find("matched", 1, true) then
      return name
    end
  end
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
  local helper_pids

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
    local deadline = os.time() + 10
    while is_running(pid) and os.time() < deadline do
      os.execute("sleep 0.1")
    end
  end

  before_each(function()
    dir = temp_dir.new()
    orphan_pid = nil
    helper_pids = {}
    shell("mkdir -p " .. quote(dir .. "/bin") .. " " .. quote(dir .. "/tests/integration"))
    write(dir .. "/bin/nvim", STUB_NVIM, true)
    write(dir .. "/bin/timeout", STUB_TIMEOUT, true)
  end)

  after_each(function()
    if orphan_pid and is_running(orphan_pid) then
      os.execute("kill -KILL " .. orphan_pid .. " 2> /dev/null")
    end
    for _, pid in ipairs(helper_pids) do
      if is_running(pid) then
        os.execute("kill -KILL " .. pid .. " 2> /dev/null")
      end
    end
    temp_dir.remove(dir)
  end)

  ---@param specs { name: string, exit: integer, output: string[], orphan: boolean|nil, ignore_term: boolean|nil }[]
  ---@param locale string|nil The LC_ALL to run the script under
  ---@return string status
  ---@return string output
  ---@return string[] ran
  local function run_script(specs, locale)
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
      .. " && TMPDIR="
      .. quote(dir:match("^(.*)/[^/]+$"))
      .. " PATH="
      .. quote(dir .. "/bin")
      .. ':"$PATH" STUB_DIR='
      .. quote(dir)
      .. " REAL_TIMEOUT="
      .. quote(real_timeout)
      .. (locale and " LC_ALL=" .. quote(locale) or "")
    local pipe = assert(io.popen(command .. " " .. quote(script) .. " 2>&1; echo status=$?"))
    local output = pipe:read("*a")
    pipe:close()
    for _, spec in ipairs(specs) do
      local pid_file = spec.ignore_term and io.open(dir .. "/" .. spec.name .. ".helper.pid")
      if pid_file then
        table.insert(helper_pids, pid_file:read("*l"))
        pid_file:close()
      end
    end
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

  it("gives a file that exits on its own the runner's own timeouts", function()
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("0", status, output)
    local log = assert(io.open(dir .. "/timeout_args"))
    local args = log:read("*a")
    log:close()
    assert.are.equal("-k 5s 40s\n", args)
  end)

  -- plenary's test_file ends a file at 50s on its own: exit 1, no TIMEOUT line, and its nvim left running.
  local PLENARY_FILE_TIMEOUT_SECONDS = 50

  ---@return integer kill_grace_seconds
  ---@return integer limit_seconds
  local function timeout_limits()
    local log = assert(io.open(dir .. "/timeout_args"))
    local args = log:read("*a")
    log:close()
    local grace, limit = args:match("^%-k (%d+)s (%d+)s\n$")
    assert(grace and limit, args)
    return tonumber(grace), tonumber(limit)
  end

  it("stops a file before plenary's own per-file timeout can", function()
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("0", status, output)
    local grace, limit = timeout_limits()
    assert.is_true(limit + grace < PLENARY_FILE_TIMEOUT_SECONDS, "limit " .. limit .. "s, grace " .. grace .. "s")
  end)

  it("names in its TIMEOUT line the limit it gave timeout", function()
    local status, output = run_script({
      { name = "hang_spec.lua", exit = 124, output = hung_output("hang_spec.lua") },
    })

    assert.are.equal("1", status, output)
    local _, limit = timeout_limits()
    assert.is_truthy(output:find("nvim did not exit within " .. limit .. "s", 1, true), output)
  end)

  ---@return table[] seen One entry for each file the stub nvim ran, with the strings viminit, minimal_init, state_home,
  ---config_home, folders and data_home
  local function env_seen()
    local seen = {}
    local log = assert(io.open(dir .. "/env_seen"))
    for line in log:lines() do
      local viminit, minimal_init, state_home, config_home, folders, data_home =
        line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
      assert(viminit, line)
      table.insert(seen, {
        viminit = viminit,
        minimal_init = minimal_init,
        state_home = state_home,
        config_home = config_home,
        folders = folders,
        data_home = data_home,
      })
    end
    log:close()
    return seen
  end

  -- A Neovim without -u runs VIMINIT. This runs it with `vim.env` and `dofile` stood in for.
  ---@param viminit string
  ---@param variable string|nil The value of CLAUDECODE_MINIMAL_INIT
  ---@return string[] loaded What the command passed to dofile
  local function files_loaded_by(viminit, variable)
    local command = assert(viminit:match("^lua (.+)$"), "VIMINIT is a lua command, not " .. viminit)
    local loaded = {}
    local chunk = assert(loadstring(command))
    setfenv(chunk, {
      vim = { env = { CLAUDECODE_MINIMAL_INIT = variable } },
      dofile = function(path)
        table.insert(loaded, tostring(path))
      end,
    })
    chunk()
    return loaded
  end

  it("makes the Neovim that plenary starts for a spec run tests/minimal_init.lua by its absolute path", function()
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("0", status, output)
    local seen = env_seen()[1]
    assert.are.same({ dir .. "/tests/minimal_init.lua" }, files_loaded_by(seen.viminit, seen.minimal_init))
  end)

  it("loads no file when CLAUDECODE_MINIMAL_INIT is missing, as dofile(nil) would read standard input", function()
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("0", status, output)
    assert.are.same({}, files_loaded_by(env_seen()[1].viminit, nil))
  end)

  it("leaves XDG_DATA_HOME alone, because plenary lives there", function()
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("0", status, output)
    assert.are.equal(os.getenv("XDG_DATA_HOME") or "unset", env_seen()[1].data_home)
  end)

  it("gives the Neovim of each file its own state and config folders and removes them afterwards", function()
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
      { name = "b_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("0", status, output)
    local seen = env_seen()
    assert.are.equal(2, #seen)
    assert.are_not.equal(seen[1].state_home, seen[2].state_home)
    assert.are_not.equal(seen[1].config_home, seen[2].config_home)
    for _, entry in ipairs(seen) do
      assert.are_not.equal("unset", entry.state_home)
      assert.are_not.equal("unset", entry.config_home)
      assert.are_not.equal(entry.state_home, entry.config_home)
      assert.are.equal("present", entry.folders, "both folders exist while the Neovim runs")
      shell("test ! -e " .. quote(entry.state_home) .. " && test ! -e " .. quote(entry.config_home))
    end
  end)

  it("starts its own Neovim without a ShaDa file, because the Neovim of plenary shares its folders", function()
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("0", status, output)
    local log = assert(io.open(dir .. "/nvim_args"))
    local args = log:read("*a")
    log:close()
    local tokens = {}
    for token in args:gmatch("%S+") do
      table.insert(tokens, token)
    end
    local has_no_shada = false
    for index, token in ipairs(tokens) do
      if token == "-i" and tokens[index + 1] == "NONE" then
        has_no_shada = true
      end
    end
    assert.is_true(has_no_shada, args)
  end)

  ---@class SignalRun
  ---@field window boolean|nil Send the signal when timeout has started but has not made its process group yet
  ---@field deaf_to_term boolean|nil The file's Neovim ignores SIGTERM
  ---@field caller_loop boolean|nil Run the runner twice in a calling shell and send the signal to their process group

  ---@param signal string The signal to send
  ---@param run SignalRun
  ---@return table result `status` of the runner (of the calling shell with `caller_loop`), `left` in its TMPDIR once
  --- its Neovim's grandchild would have written, `ended` when the file's Neovim got to the end of its 2 second run,
  --- `runner_output` (stdout and stderr of the runner), and `caller_output` of the calling shell
  local function signal_runner(signal, run)
    write(dir .. "/tests/integration/slow_spec.lua", {})
    write(dir .. "/slow_spec.lua.out", summary(1, 0, 0))
    write(dir .. "/slow_spec.lua.exit", { "0" })
    write(dir .. "/slow_spec.lua.sleep", {})
    if run.window then
      write(dir .. "/slow_spec.lua.window", {})
    end
    if run.deaf_to_term then
      write(dir .. "/slow_spec.lua.deaf_to_term", {})
    end
    local temp = dir .. "/tmp"
    shell("mkdir -p " .. quote(temp))
    local runner_out = " > " .. quote(dir .. "/runner.out") .. " 2>&1"
    local job = quote(script) .. runner_out
    local target = "$pid"
    if run.caller_loop then
      job = "bash -c " .. quote('for i in 1 2; do "$0" > ' .. quote(dir .. "/runner.out") .. " 2>&1; echo ran=$i; done")
      job = job .. " " .. quote(script) .. " > " .. quote(dir .. "/caller.out") .. " 2>&1"
      target = "-- -$pid"
    end
    -- `set -m` gives the background job its own process group and leaves SIGINT unignored, as a runner has at a prompt.
    local inner = "cd "
      .. quote(dir)
      .. " && export TMPDIR="
      .. quote(temp)
      .. " PATH="
      .. quote(dir .. "/bin")
      .. ':"$PATH" STUB_DIR='
      .. quote(dir)
      .. " REAL_TIMEOUT="
      .. quote(real_timeout)
      .. "; set -m; "
      .. job
      .. " & pid=$!; for _ in $(seq 100); do [ -e "
      .. quote(dir .. (run.window and "/slow_spec.lua.timeout_started" or "/slow_spec.lua.started"))
      .. " ] && break; sleep 0.1; done; kill -"
      .. signal
      .. " "
      .. target
      .. "; wait $pid; echo status=$?; sleep 3"
    local pipe = assert(io.popen("bash -c " .. quote(inner)))
    local output = pipe:read("*a")
    pipe:close()
    local listing = assert(io.popen("ls -A " .. quote(temp)))
    local left = listing:read("*a")
    listing:close()
    local caller = io.open(dir .. "/caller.out")
    local caller_output = caller and caller:read("*a") or ""
    if caller then
      caller:close()
    end
    local runner = io.open(dir .. "/runner.out")
    local runner_output = runner and runner:read("*a") or ""
    if runner then
      runner:close()
    end
    local ended = io.open(dir .. "/slow_spec.lua.ended")
    if ended then
      ended:close()
    end
    return {
      status = output:match("status=(%d+)") or output,
      left = left,
      ended = ended ~= nil,
      caller_output = caller_output,
      runner_output = runner_output,
    }
  end

  for _, case in ipairs({ { "SIGTERM", "TERM", "143" }, { "SIGINT", "INT", "130" } }) do
    local name, signal, expected_status = case[1], case[2], case[3]
    local description = "stops the running file and removes its temp files and folders on "
    it(description .. name .. " at once, and exits " .. expected_status, function()
      local result = signal_runner(signal, {})

      assert.are.equal(expected_status, result.status)
      assert.are.equal("", result.left, "the runner left temp files behind, or its Neovim's grandchild ran on")
      assert.is_false(result.ended, "the runner waited for the file to end, it did not stop it")
      assert.is_nil(
        result.runner_output:find("line %d+:"),
        "bash printed a report of the killed job: " .. result.runner_output
      )
    end)
  end

  it("stops a file whose Neovim ignores SIGTERM when the runner gets SIGTERM", function()
    local result = signal_runner("TERM", { deaf_to_term = true })

    assert.are.equal("143", result.status)
    assert.are.equal("", result.left, "a Neovim that ignores SIGTERM ran on after the runner died")
    assert.is_false(result.ended)
  end)

  it("stops a file on SIGTERM that arrives after timeout started and before it made its process group", function()
    local result = signal_runner("TERM", { window = true })

    assert.are.equal("143", result.status)
    assert.are.equal("", result.left, "the runner left temp files or folders behind")
    assert.is_nil(io.open(dir .. "/slow_spec.lua.started"), "the file's Neovim started after the runner died")
  end)

  it("dies by SIGINT on Ctrl-C, so a shell that calls it in a loop stops the loop", function()
    local result = signal_runner("INT", { caller_loop = true })

    assert.are.equal("130", result.status)
    assert.are.equal("", result.caller_output, "the calling shell went on after the runner got Ctrl-C")
    assert.are.equal("", result.left, "the runner left temp files or folders behind")
    assert.is_false(result.ended)
  end)

  it("shortens only the kill grace of the file that ignores SIGTERM", function()
    local status, output, ran = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
      { name = "stuck_spec.lua", exit = 0, output = hung_output("stuck_spec.lua"), ignore_term = true },
      { name = "z_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("1", status, output)
    assert.are.same({ "a_spec.lua", "stuck_spec.lua", "z_spec.lua" }, ran)
    assert.is_truthy(output:find("Failed test files:\n  - stuck_spec.lua\n\n", 1, true), output)
    local log = assert(io.open(dir .. "/timeout_args"))
    local args = log:read("*a")
    log:close()
    assert.are.equal("-k 5s 40s\n-k 1s 40s\n-k 5s 40s\n", args)
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

  it("fails a file whose nvim exited 0 after passing tests without printing a summary", function()
    local status, output = run_script({
      { name = "stopped_spec.lua", exit = 0, output = { row("Success", "first"), row("Success", "second") } },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("FAILED: stopped_spec.lua: no plenary summary (nvim exit 0)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - stopped_spec.lua", 1, true), output)
    assert.is_truthy(output:find("Total Errors: 1\n", 1, true), output)
    assert.is_nil(output:find("All integration tests passed!", 1, true), output)
    assert.is_nil(output:find("TIMEOUT", 1, true), output)
  end)

  it("fails a file that printed a Fail row, then stopped with exit 0 and no summary", function()
    local status, output = run_script({
      {
        name = "assert_spec.lua",
        exit = 0,
        output = {
          row("Fail", "a test that failed"),
          "            ...:69: Expected objects to be equal.",
          row("Success", "a test that passed"),
          "LuaJIT ASSERT lj_api.c:40: index2adr: bad stack slot -1",
        },
      },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("FAILED: assert_spec.lua: no plenary summary (nvim exit 0)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - assert_spec.lua", 1, true), output)
  end)

  for index, line in ipairs({ "Success:", "Failed :", "Errors :" }) do
    it("fails a file whose summary lacks its " .. line .. " line", function()
      local status, output = run_script({
        { name = "partial_spec.lua", exit = 0, output = without(summary(3, 0, 0), index) },
      })

      assert.are.equal("1", status, output)
      assert.is_truthy(output:find("FAILED: partial_spec.lua: no plenary summary (nvim exit 0)", 1, true), output)
      assert.is_truthy(output:find("Failed test files:\n  - partial_spec.lua", 1, true), output)
    end)
  end

  it("fails a file whose count has a leading zero and still runs the next file", function()
    local status, output, ran = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(3, "08", 0) },
      { name = "z_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("1", status, output)
    assert.are.same({ "a_spec.lua", "z_spec.lua" }, ran)
    assert.is_truthy(output:find("FAILED: a_spec.lua: no plenary summary (nvim exit 0)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - a_spec.lua\n\n", 1, true), output)
  end)

  it("fails a file whose success count has a leading zero and still runs the next file", function()
    local status, output, ran = run_script({
      { name = "a_spec.lua", exit = 0, output = summary("08", 0, 0) },
      { name = "z_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("1", status, output)
    assert.are.same({ "a_spec.lua", "z_spec.lua" }, ran)
    assert.is_truthy(output:find("FAILED: a_spec.lua: no plenary summary (nvim exit 0)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - a_spec.lua\n\n", 1, true), output)
  end)

  it("fails a file whose count is not a number and still runs the next file", function()
    local status, output, ran = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(3, 0, "many") },
      { name = "z_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("1", status, output)
    assert.are.same({ "a_spec.lua", "z_spec.lua" }, ran)
    assert.is_truthy(output:find("FAILED: a_spec.lua: no plenary summary (nvim exit 0)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - a_spec.lua\n\n", 1, true), output)
  end)

  it("fails a file whose failure count has more than 9 digits and still runs the next file", function()
    local status, output, ran = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(3, "18446744073709551615", 0) },
      { name = "z_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("1", status, output)
    assert.are.same({ "a_spec.lua", "z_spec.lua" }, ran)
    assert.is_truthy(output:find("FAILED: a_spec.lua: no plenary summary (nvim exit 0)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - a_spec.lua\n\n", 1, true), output)
  end)

  it("fails a file whose error count has more than 9 digits and still runs the next file", function()
    local status, output, ran = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(3, 0, "9223372036854775808") },
      { name = "z_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("1", status, output)
    assert.are.same({ "a_spec.lua", "z_spec.lua" }, ran)
    assert.is_truthy(output:find("FAILED: a_spec.lua: no plenary summary (nvim exit 0)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - a_spec.lua\n\n", 1, true), output)
  end)

  it("takes a count of 999999999 as a count", function()
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(999999999, 0, 0) },
    })

    assert.are.equal("0", status, output)
    assert.is_truthy(output:find("Total Success: 999999999\nTotal Failed: 0\nTotal Errors: 0\n", 1, true), output)
  end)

  it("fails a file whose count has 10 digits and still runs the next file", function()
    local status, output, ran = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1000000000, 0, 0) },
      { name = "z_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("1", status, output)
    assert.are.same({ "a_spec.lua", "z_spec.lua" }, ran)
    assert.is_truthy(output:find("FAILED: a_spec.lua: no plenary summary (nvim exit 0)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - a_spec.lua\n\n", 1, true), output)
  end)

  local wide_digit_locale = find_wide_digit_locale()
  local it_in_wide_digit_locale = wide_digit_locale and it or function(name)
    pending(name)
  end

  for index, count_name in ipairs({ "Success:", "Failed :", "Errors :" }) do
    for _, wide in ipairs({
      { text = "is a wide digit", count = "１" },
      { text = "has a wide digit after an ASCII digit", count = "1１" },
    }) do
      local counts = { 3, 0, 0 }
      counts[index] = wide.count
      it_in_wide_digit_locale(
        "fails a file whose " .. count_name .. " count " .. wide.text .. " and still runs the next file",
        function()
          local status, output, ran = run_script({
            { name = "a_spec.lua", exit = 0, output = summary(unpack(counts)) },
            { name = "z_spec.lua", exit = 0, output = summary(1, 0, 0) },
          }, wide_digit_locale)

          assert.are.equal("1", status, output)
          assert.are.same({ "a_spec.lua", "z_spec.lua" }, ran)
          assert.is_truthy(output:find("FAILED: a_spec.lua: no plenary summary (nvim exit 0)", 1, true), output)
          assert.is_truthy(output:find("Failed test files:\n  - a_spec.lua\n\n", 1, true), output)
        end
      )
    end
  end

  it("fails a file whose summary counts a failure although nvim exited 0", function()
    local status, output = run_script({
      { name = "failing_spec.lua", exit = 0, output = summary(2, 1, 0) },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("Failed test files:\n  - failing_spec.lua", 1, true), output)
    assert.is_nil(output:find("no plenary summary", 1, true), output)
  end)

  it("fails a file whose summary counts an error although nvim exited 0", function()
    local status, output = run_script({
      { name = "erroring_spec.lua", exit = 0, output = summary(2, 0, 1) },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("Failed test files:\n  - erroring_spec.lua", 1, true), output)
    assert.is_nil(output:find("no plenary summary", 1, true), output)
  end)

  it("passes a file whose output has a line that starts with Fail ||", function()
    local status, output = run_script({
      {
        name = "diagnostic_spec.lua",
        exit = 0,
        output = concat({ "Fail || x", row("Fail", "x"), row("Success", "one") }, summary(1, 0, 0)),
      },
    })

    assert.are.equal("0", status, output)
    assert.is_truthy(output:find("All integration tests passed!", 1, true), output)
  end)

  it("passes a file whose output has a line that starts with Error ||", function()
    local status, output = run_script({
      {
        name = "diagnostic_spec.lua",
        exit = 0,
        output = concat({ "Error || x", row("Success", "one") }, summary(1, 0, 0)),
      },
    })

    assert.are.equal("0", status, output)
    assert.is_truthy(output:find("All integration tests passed!", 1, true), output)
  end)

  it("ignores a Failed : line that does not start the line", function()
    local status, output = run_script({
      { name = "note_spec.lua", exit = 0, output = concat(summary(2, 0, 0), { "note:Failed : 1" }) },
    })

    assert.are.equal("0", status, output)
    assert.is_truthy(output:find("Total Success: 2\nTotal Failed: 0\nTotal Errors: 0\n", 1, true), output)
  end)

  it("ignores an Errors : line that does not start the line", function()
    local status, output = run_script({
      { name = "note_spec.lua", exit = 0, output = concat(summary(2, 0, 0), { "note:Errors : 1" }) },
    })

    assert.are.equal("0", status, output)
    assert.is_truthy(output:find("Total Success: 2\nTotal Failed: 0\nTotal Errors: 0\n", 1, true), output)
  end)

  it("fails a file whose only Success: line does not start the line", function()
    local status, output = run_script({
      { name = "note_spec.lua", exit = 0, output = concat({ "note:Success: 3" }, without(summary(3, 0, 0), 1)) },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("FAILED: note_spec.lua: no plenary summary (nvim exit 0)", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - note_spec.lua", 1, true), output)
  end)

  it("fails a file whose last summary counts a failure after a clean one", function()
    local status, output = run_script({
      {
        name = "lookalike_spec.lua",
        exit = 0,
        output = concat(summary(5, 0, 0), { "plenary again" }, summary(1, 1, 0)),
      },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("Failed test files:\n  - lookalike_spec.lua", 1, true), output)
    assert.is_nil(output:find("no plenary summary", 1, true), output)
  end)

  it("passes a file whose last summary is clean after one that counts failures", function()
    local status, output = run_script({
      {
        name = "lookalike_spec.lua",
        exit = 0,
        output = concat(summary(1, 1, 1), { "plenary again" }, summary(4, 0, 0)),
      },
    })

    assert.are.equal("0", status, output)
    assert.is_truthy(output:find("Total Success: 4\nTotal Failed: 0\nTotal Errors: 0\n", 1, true), output)
  end)

  it("adds up the summary counts in the totals, whatever rows the output has", function()
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = concat({ row("Success", "one") }, summary(7, 0, 0)) },
      { name = "b_spec.lua", exit = 0, output = summary(5, 0, 0) },
      { name = "c_spec.lua", exit = 1, output = summary(2, 1, 0) },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("Total Success: 14\nTotal Failed: 1\nTotal Errors: 0\n", 1, true), output)
  end)

  it("passes a file whose tests are all pending", function()
    local status, output = run_script({
      {
        name = "pending_spec.lua",
        exit = 0,
        output = concat({ row("Pending", "needs Neovim 0.9") }, summary(0, 0, 0)),
      },
    })

    assert.are.equal("0", status, output)
    assert.is_truthy(output:find("All integration tests passed!", 1, true), output)
    assert.is_truthy(output:find("Total Success: 0\n", 1, true), output)
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

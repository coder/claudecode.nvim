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
  'if [ -f "$STUB_DIR/$name.ignore_term" ] || [ -f "$STUB_DIR/$name.outside_term" ]; then',
  "  pid=$$",
  '  (while kill -0 "$pid"; do',
  '    if [ -f "$STUB_DIR/$name.ready" ]; then kill -TERM "$pid"; break; fi',
  "    sleep 0.05",
  "  done) > /dev/null 2>&1 &",
  '  echo $! > "$STUB_DIR/$name.helper.pid"',
  '  if [ -f "$STUB_DIR/$name.ignore_term" ] && [ "$1" = -k ]; then',
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
  "for fd in /proc/$$/fd/*; do",
  '  case "$(readlink "$fd" 2> /dev/null)" in */exit_statuses*) : > "$STUB_DIR/$name.holds_status_file" ;; esac',
  "done",
  'echo "$*" >> "$STUB_DIR/nvim_args"',
  'if [ -f "$STUB_DIR/$name.sleep" ]; then',
  '  if [ -f "$STUB_DIR/$name.deaf_to_term" ]; then trap "" TERM; fi',
  '  : > "$STUB_DIR/$name.started"',
  '  if [ -f "$STUB_DIR/$name.write_on_cue" ]; then',
  '    (for tick in $(seq 400); do [ -e "$STUB_DIR/$name.cue" ] && break; sleep 0.05; done;',
  '      mkdir -p "$XDG_STATE_HOME/nvim" && : > "$XDG_STATE_HOME/nvim/shada"; : > "$STUB_DIR/$name.written"; sleep 20) &',
  "  else",
  '    (sleep 2; mkdir -p "$XDG_STATE_HOME/nvim" && : > "$XDG_STATE_HOME/nvim/shada") &',
  "  fi",
  "  wait",
  '  : > "$STUB_DIR/$name.ended"',
  "fi",
  "folders=missing",
  'if [ -d "$XDG_STATE_HOME" ] && [ -d "$XDG_CONFIG_HOME" ] && [ -d "$TMPDIR" ]; then folders=present; fi',
  'printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "${VIMINIT-unset}" "${CLAUDECODE_MINIMAL_INIT-unset}" \\',
  '  "${XDG_STATE_HOME-unset}" "${XDG_CONFIG_HOME-unset}" "$folders" "${XDG_DATA_HOME-unset}" \\',
  '  "${TMPDIR-unset}" "${XDG_RUNTIME_DIR-unset}" >> "$STUB_DIR/env_seen"',
  'if [ -f "$STUB_DIR/$name.ignore_term" ] || [ -f "$STUB_DIR/$name.outside_term" ]; then',
  '  if [ -f "$STUB_DIR/$name.ignore_term" ]; then trap "" TERM; fi',
  '  : > "$STUB_DIR/$name.ready"',
  "  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sleep 1; done",
  "fi",
  'if [ -f "$STUB_DIR/$name.orphan" ]; then',
  "  sh -c 'trap \"\" TERM; exec sleep 60' > /dev/null 2>&1 &",
  '  echo $! > "$STUB_DIR/$name.orphan.pid"',
  "fi",
  'cat "$STUB_DIR/$name.out"',
  'if [ -f "$STUB_DIR/$name.remove_state" ]; then rm -rf "$XDG_STATE_HOME"; fi',
  'if [ -f "$STUB_DIR/$name.die_by" ]; then kill -"$(cat "$STUB_DIR/$name.die_by")" $$; fi',
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

-- The nvim, tee and rm stubs list the files they hold open from /proc/<pid>/fd. Where it does not exist they list
-- nothing, and a runner that keeps a descriptor open would pass the test that reads their notes.
local has_proc_fd = (function()
  local status = os.execute("test -d /proc/self/fd")
  return status == 0 or status == true
end)()

-- The runner moves the temp folder of a file to /tmp when TMPDIR is long, and it needs a /tmp that it can write to.
local tmp_is_writable = (function()
  local status = os.execute("test -d /tmp && test -w /tmp")
  return status == 0 or status == true
end)()

-- A process that nohup or a similar launcher started has SIGHUP ignored, and every process below it ignores it too. Bash
-- cannot trap a signal that was ignored when it started, so a runner there ignores that signal.
---@param signal string
---@return boolean ignored
local function signal_is_ignored(signal)
  local pipe = assert(io.popen("bash -c 'trap -p " .. signal .. "'"))
  local trapped = pipe:read("*a")
  pipe:close()
  return trapped:find("''", 1, true) ~= nil
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

local tee_pipe = assert(io.popen("command -v tee 2> /dev/null"))
local real_tee = assert(tee_pipe:read("*l"), "needs tee")
tee_pipe:close()
-- Copies its input like tee, then exits with the status in $STUB_DIR/tee.exit when that file exists, after the seconds
-- in $STUB_DIR/tee.delay when that file exists. When $STUB_DIR/tee.hold exists, it notes in $STUB_DIR/tee.held and waits
-- for $STUB_DIR/tee.go before it starts the real tee, which opens its output file. The wait ends after 20 seconds at
-- most, so a runner that never releases it fails its test and does not hang it.
local STUB_TEE = {
  "#!/bin/sh",
  'if [ -f "$STUB_DIR/tee.hold" ]; then : > "$STUB_DIR/tee.held"; for tick in $(seq 400); do [ -e "$STUB_DIR/tee.go" ] && break; sleep 0.05; done; fi',
  quote(real_tee) .. ' "$@"',
  "status=$?",
  -- After the real tee, so that the output file is opened as early as it is for the real tee.
  "for fd in /proc/$$/fd/*; do",
  '  case "$(readlink "$fd" 2> /dev/null)" in */exit_statuses*) : > "$STUB_DIR/tee.holds_status_file" ;; esac',
  "done",
  'if [ -f "$STUB_DIR/tee.exit" ]; then status=$(cat "$STUB_DIR/tee.exit"); fi',
  'if [ -f "$STUB_DIR/tee.delay" ]; then sleep "$(cat "$STUB_DIR/tee.delay")"; fi',
  'exit "$status"',
}

local mktemp_pipe = assert(io.popen("command -v mktemp 2> /dev/null"))
local real_mktemp = assert(mktemp_pipe:read("*l"), "needs mktemp")
mktemp_pipe:close()
-- Runs the real mktemp. When $STUB_DIR/mktemp.interrupt exists, its first call sends SIGINT to its process group, which
-- has the runner in it, after the real mktemp ran and before it prints the name. When $STUB_DIR/mktemp.name exists, a
-- call with -u and no template makes nothing and prints the name in that file.
local STUB_MKTEMP = {
  "#!/bin/sh",
  'if [ -f "$STUB_DIR/mktemp.name" ] && [ "$1" = -u ] && [ -z "${2:-}" ]; then cat "$STUB_DIR/mktemp.name"; exit 0; fi',
  "path=$(" .. quote(real_mktemp) .. ' "$@") || exit $?',
  'if [ -f "$STUB_DIR/mktemp.interrupt" ] && [ ! -f "$STUB_DIR/mktemp.interrupted" ]; then',
  '  : > "$STUB_DIR/mktemp.interrupted"',
  '  trap "" INT',
  "  kill -s INT 0",
  "fi",
  'echo "$path"',
}

local mkdir_pipe = assert(io.popen("command -v mkdir 2> /dev/null"))
local real_mkdir = assert(mkdir_pipe:read("*l"), "needs mkdir")
mkdir_pipe:close()
-- Runs the real mkdir. When $STUB_DIR/mkdir.drop_state exists, it then removes each folder named state that it made, so
-- that the folder does not exist when the runner opens the status file in it. When $STUB_DIR/mkdir.block_group exists,
-- its first call also makes a folder named group in the folder that it made, where the runner's shell writes a file.
-- When $STUB_DIR/mkdir.interrupt exists, the call that the number in $STUB_DIR/mkdir.at names (the first by default)
-- sends the signal named in that file. SIGINT goes to its process group, which has the runner in it, after the real
-- mkdir ran. Any other signal goes to the runner alone, before the real mkdir runs, and the stub then waits up to 3
-- seconds for the runner to end or for its rm to stop in the middle (see the rm stub), so that a runner that dies at
-- once is gone, or removing its folder, before this mkdir makes a folder. It lets the rm go afterwards.
local STUB_MKDIR = {
  "#!/bin/sh",
  'n=$(( $(cat "$STUB_DIR/mkdir.count" 2> /dev/null || echo 0) + 1 ))',
  'echo "$n" > "$STUB_DIR/mkdir.count"',
  "at=1",
  '[ -f "$STUB_DIR/mkdir.at" ] && at=$(cat "$STUB_DIR/mkdir.at")',
  "sig=",
  'if [ -f "$STUB_DIR/mkdir.interrupt" ] && [ "$n" = "$at" ]; then',
  '  sig=$(cat "$STUB_DIR/mkdir.interrupt")',
  '  if [ "$sig" != INT ]; then',
  '    kill -s "$sig" "$PPID"',
  '    for _ in $(seq 60); do kill -0 "$PPID" 2> /dev/null && [ ! -e "$STUB_DIR/rm.held" ] || break; sleep 0.05; done',
  "  fi",
  "fi",
  quote(real_mkdir) .. ' "$@"',
  "status=$?",
  'if [ -f "$STUB_DIR/mkdir.drop_state" ]; then',
  '  for path in "$@"; do case "$path" in */state) rmdir "$path" ;; esac; done',
  "fi",
  'if [ -f "$STUB_DIR/mkdir.block_group" ] && [ "$n" = 1 ]; then',
  '  for path in "$@"; do [ -d "$path" ] && ' .. quote(real_mkdir) .. ' "$path/group"; done',
  "fi",
  'if [ "$sig" = INT ]; then',
  '  trap "" INT',
  "  kill -s INT 0",
  'elif [ -n "$sig" ]; then',
  '  : > "$STUB_DIR/rm.release"',
  "fi",
  'exit "$status"',
}

local mv_pipe = assert(io.popen("command -v mv 2> /dev/null"))
local real_mv = assert(mv_pipe:read("*l"), "needs mv")
mv_pipe:close()
-- Runs the real mv, except when $STUB_DIR/mv.fail exists: then it fails and moves nothing. When $STUB_DIR/mv.hold
-- exists, it notes in $STUB_DIR/mv.held and waits for $STUB_DIR/mv.release, 20 seconds at most, before the real mv.
local STUB_MV = {
  "#!/bin/sh",
  'if [ -f "$STUB_DIR/mv.fail" ]; then exit 1; fi',
  'if [ -f "$STUB_DIR/mv.hold" ]; then : > "$STUB_DIR/mv.held"; for tick in $(seq 400); do [ -e "$STUB_DIR/mv.release" ] && break; sleep 0.05; done; fi',
  "exec " .. quote(real_mv) .. ' "$@"',
}

local cat_pipe = assert(io.popen("command -v cat 2> /dev/null"))
local real_cat = assert(cat_pipe:read("*l"), "needs cat")
cat_pipe:close()
-- Runs the real cat, except when $STUB_DIR/cat.hold exists: then the call that reads a process id file in a folder that
-- the cleanup moved (a path that ends in /work/group) notes in $STUB_DIR/cat.held and waits for $STUB_DIR/cat.release,
-- 20 seconds at most, before the real cat.
local STUB_CAT = {
  "#!/bin/sh",
  'if [ -f "$STUB_DIR/cat.hold" ]; then',
  '  case "$1" in */work/group)',
  '    : > "$STUB_DIR/cat.held"',
  '    for tick in $(seq 400); do [ -e "$STUB_DIR/cat.release" ] && break; sleep 0.05; done',
  "    ;;",
  "  esac",
  "fi",
  "exec " .. quote(real_cat) .. ' "$@"',
}

-- BASH_ENV files for the shell that execs timeout. Bash reads such a file first in each non-interactive shell, and only
-- that shell has CLAUDECODE_MINIMAL_INIT. The first file stops the shell before its first command, as long as
-- $STUB_DIR/a.release does not exist. The second file wraps echo, which the shell calls to write its process id: the
-- redirection of the call has made the file by then, and the wrapper stops the shell before the write. Both stop it for
-- 20 seconds at most.
local HOLD_START = {
  'if [ -n "${CLAUDECODE_MINIMAL_INIT:-}" ]; then',
  '  : > "$STUB_DIR/a.held"',
  '  for tick in $(seq 400); do [ -e "$STUB_DIR/a.release" ] && break; sleep 0.05; done',
  "fi",
}
local HOLD_WRITE = {
  'if [ -n "${CLAUDECODE_MINIMAL_INIT:-}" ]; then',
  "  echo() {",
  '    : > "$STUB_DIR/a.held"',
  '    for tick in $(seq 400); do [ -e "$STUB_DIR/a.release" ] && break; sleep 0.05; done',
  '    builtin echo "$@"',
  "  }",
  "fi",
}

local rm_pipe = assert(io.popen("command -v rm 2> /dev/null"))
local real_rm = assert(rm_pipe:read("*l"), "needs rm")
rm_pipe:close()
-- Notes in $STUB_DIR/rm.holds_status_file that it holds the status file open. When $STUB_DIR/rm.second_signal exists,
-- its first call deletes the files and sends the signal that the file names to its process group, which has the
-- runner in it, as a second Ctrl-C does. An rm that does not ignore the signal dies of it. A call that lives on notes
-- it in $STUB_DIR/rm.survived and goes on as below. Runs the real rm and then exits with 1
-- when $STUB_DIR/rm.fail exists, as rm does when a folder is not empty. Runs the real rm, except when
-- $STUB_DIR/rm.slow or $STUB_DIR/rm.hold exists: then it walks the way rm -rf does, but slowly. It lists the folders,
-- deletes the files, waits, and only then removes the listed folders, so a file or a folder that something makes
-- meanwhile stops the removal of its parent ("Directory not empty"), as it does for a slow rm -rf under strace. It waits
-- the seconds in rm.slow, or with rm.hold it notes in $STUB_DIR/rm.held and waits for $STUB_DIR/rm.release, 20 seconds
-- at most.
local STUB_RM = {
  "#!/bin/sh",
  "for fd in /proc/$$/fd/*; do",
  '  case "$(readlink "$fd" 2> /dev/null)" in */exit_statuses*) : > "$STUB_DIR/rm.holds_status_file" ;; esac',
  "done",
  'if [ -f "$STUB_DIR/rm.fail" ]; then ' .. quote(real_rm) .. ' "$@"; exit 1; fi',
  'if [ -f "$STUB_DIR/rm.second_signal" ] && [ ! -f "$STUB_DIR/rm.sent" ]; then',
  '  : > "$STUB_DIR/rm.sent"',
  '  (shift; for path in "$@"; do find "$path" -type f -delete; done) 2> /dev/null',
  '  kill -s "$(cat "$STUB_DIR/rm.second_signal")" 0',
  '  : > "$STUB_DIR/rm.survived"',
  "fi",
  'if [ ! -f "$STUB_DIR/rm.slow" ] && [ ! -f "$STUB_DIR/rm.hold" ]; then exec ' .. quote(real_rm) .. ' "$@"; fi',
  "shift",
  ': > "$STUB_DIR/rm.dirs"',
  'for path in "$@"; do find "$path" -depth -type d >> "$STUB_DIR/rm.dirs"; find "$path" -type f -delete; done 2> /dev/null',
  'if [ -f "$STUB_DIR/rm.hold" ]; then',
  '  : > "$STUB_DIR/rm.held"',
  '  for tick in $(seq 400); do [ -e "$STUB_DIR/rm.release" ] && break; sleep 0.05; done',
  "else",
  '  sleep "$(cat "$STUB_DIR/rm.slow")"',
  "fi",
  "status=0",
  'while read -r folder; do rmdir "$folder" || status=1; done < "$STUB_DIR/rm.dirs"',
  'exit "$status"',
}

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
    write(dir .. "/bin/tee", STUB_TEE, true)
    write(dir .. "/bin/rm", STUB_RM, true)
    write(dir .. "/bin/mktemp", STUB_MKTEMP, true)
    write(dir .. "/bin/mkdir", STUB_MKDIR, true)
    write(dir .. "/bin/mv", STUB_MV, true)
    write(dir .. "/bin/cat", STUB_CAT, true)
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

  ---@class ScriptSpec
  ---@field name string
  ---@field exit integer
  ---@field output string[]
  ---@field orphan boolean|nil
  ---@field ignore_term boolean|nil
  ---@field outside_term boolean|nil An outside SIGTERM reaches timeout while the stub nvim sleeps, and nvim dies of it
  ---@field die_by string|nil A signal the stub nvim sends itself after its output, as `kill -<die_by>` takes it
  ---@field remove_state boolean|nil The stub nvim deletes its state folder after its output

  ---@param specs ScriptSpec[]
  ---@param locale string|nil The LC_ALL to run the script under
  ---@param tmp string|nil The TMPDIR to run the script under, a folder that exists
  ---@return string status
  ---@return string output
  ---@return string[] ran
  local function run_script(specs, locale, tmp)
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
      if spec.outside_term then
        write(dir .. "/" .. spec.name .. ".outside_term", {})
      end
      if spec.die_by then
        write(dir .. "/" .. spec.name .. ".die_by", { spec.die_by })
      end
      if spec.remove_state then
        write(dir .. "/" .. spec.name .. ".remove_state", {})
      end
    end
    local command = "cd "
      .. quote(dir)
      .. " && TMPDIR="
      .. quote(tmp or dir:match("^(.*)/[^/]+$"))
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
      local pid_file = (spec.ignore_term or spec.outside_term) and io.open(dir .. "/" .. spec.name .. ".helper.pid")
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
  ---config_home, folders, data_home, tmpdir and runtime_dir
  local function env_seen()
    local seen = {}
    local log = assert(io.open(dir .. "/env_seen"))
    for line in log:lines() do
      local viminit, minimal_init, state_home, config_home, folders, data_home, tmpdir, runtime_dir =
        line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
      assert(viminit, line)
      table.insert(seen, {
        viminit = viminit,
        minimal_init = minimal_init,
        state_home = state_home,
        config_home = config_home,
        folders = folders,
        data_home = data_home,
        tmpdir = tmpdir,
        runtime_dir = runtime_dir,
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

  it("gives the Neovim of each file its own state, config and temp folders and removes them afterwards", function()
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
      { name = "b_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("0", status, output)
    local seen = env_seen()
    assert.are.equal(2, #seen)
    assert.are_not.equal(seen[1].state_home, seen[2].state_home)
    assert.are_not.equal(seen[1].config_home, seen[2].config_home)
    assert.are_not.equal(seen[1].tmpdir, seen[2].tmpdir)
    for _, entry in ipairs(seen) do
      assert.are_not.equal("unset", entry.state_home)
      assert.are_not.equal("unset", entry.config_home)
      assert.are_not.equal(entry.state_home, entry.config_home)
      assert.are_not.equal(dir .. "/tmp", entry.tmpdir, "the Neovim of the file shares the runner's TMPDIR")
      assert.are.equal(entry.tmpdir, entry.runtime_dir, "Neovim puts its socket folders in TMPDIR and XDG_RUNTIME_DIR")
      assert.are.equal("present", entry.folders, "the three folders exist while the Neovim runs")
      shell("test ! -e " .. quote(entry.state_home) .. " && test ! -e " .. quote(entry.config_home))
      shell("test ! -e " .. quote(entry.tmpdir))
    end
  end)

  it("puts the temp folder of the file in /tmp when TMPDIR is long, so a socket path stays short", function()
    if not tmp_is_writable then
      pending("needs a /tmp that the test can write to")
    end
    local long = dir .. "/" .. string.rep("t", math.max(1, 100 - #dir - 1))
    shell("mkdir -p " .. quote(long))
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
    }, nil, long)

    assert.are.equal("0", status, output)
    local seen = env_seen()
    assert.are.equal(1, #seen)
    -- The longest socket name that a Neovim makes in XDG_RUNTIME_DIR is "/nvim.<7 digits>.<2 digits>".
    assert.is_true(#seen[1].runtime_dir + 16 <= 107, "a socket path in " .. seen[1].runtime_dir .. " passes 107 bytes")
    assert.are.equal(seen[1].tmpdir, seen[1].runtime_dir)
    shell("test ! -e " .. quote(seen[1].tmpdir))
    shell('test -z "$(ls -A ' .. quote(long) .. ')"')
  end)

  it("counts the temp folder name in bytes, so a TMPDIR of multibyte characters goes to /tmp too", function()
    local probe = assert(io.popen("LC_ALL=C.utf8 bash -c 'x=\195\169; echo ${#x}' 2> /dev/null"))
    local characters = probe:read("*l")
    probe:close()
    if not tmp_is_writable or characters ~= "1" then
      pending("needs a writable /tmp and the locale C.utf8")
    end
    local long = dir .. "/" .. string.rep("\195\169", 30)
    shell("mkdir -p " .. quote(long))
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
    }, "C.utf8", long)

    assert.are.equal("0", status, output)
    local seen = env_seen()
    assert.are.equal(1, #seen)
    assert.is_true(#seen[1].runtime_dir + 16 <= 107, "a socket path in " .. seen[1].runtime_dir .. " passes 107 bytes")
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
    ---@param first string
    ---@param second string|nil The token that must follow `first`, or nil when `first` alone is enough
    ---@return boolean
    local function has(first, second)
      for index, token in ipairs(tokens) do
        if token == first and (second == nil or tokens[index + 1] == second) then
          return true
        end
      end
      return false
    end
    assert.is_true(has("-i", "NONE"), args)
    assert.is_true(has("--headless"), args)
    assert.is_true(has("-u", "tests/minimal_init.lua"), args)
  end)

  ---@class SignalRun
  ---@field window boolean|nil Send the signal when timeout has started but has not made its process group yet
  ---@field deaf_to_term boolean|nil The file's Neovim ignores SIGTERM
  ---@field caller_loop boolean|nil Run the runner twice in a calling shell and send the signal to their process group
  ---@field late_tee number|nil The file's tee ends this many seconds after its input ends
  ---@field slow_rm number|nil The runner's rm waits this many seconds between deleting files and removing folders
  ---@field rm_fails boolean|nil The runner's rm removes what it is told to and then exits with 1
  ---@field hold "start"|"write"|nil Send the signal while the shell that execs timeout waits, before its first command
  --- (start) or after its redirection made the process id file and before it writes it (write), and let it go after the
  --- runner is gone
  ---@field during_rm "launcher"|"tee"|nil Let the shell that execs timeout (which then waits before its first command)
  --- or the file's tee go while the runner's rm waits, after it deleted the files and before it removed the folders
  ---@field interrupt "mktemp"|"mkdir"|nil A call of that command sends the signal itself, and nothing else does. A mktemp
  --- sends only SIGINT
  ---@field interrupt_at integer|nil The number of the mkdir call that sends the signal, 1 by default
  ---@field rm_holds boolean|nil The runner's rm stops in the middle, as with `during_rm`, until that mkdir call ends
  ---@field second_signal "INT"|"TERM"|"HUP"|nil The first rm of the runner deletes the files, and then a second
  --- signal of that name reaches its process group
  ---@field during_mv boolean|nil The runner's mv, which renames the folder, waits until the shell that execs timeout has
  --- started the file's Neovim
  ---@field write_before_kill boolean|nil The cleanup waits after it moved the folder and before it kills, and the file's
  --- Neovim writes into the old folder path then, as a live Neovim does
  ---@field caller_reports boolean|nil Run the runner once in a calling shell, which prints the status of the runner and
  --- the report that bash prints for a child that died of a signal. Send the signal to the runner alone, with `interrupt`
  ---@field mv_fails boolean|nil The runner's mv, which renames the folder, fails

  ---@param signal string The signal to send
  ---@param run SignalRun
  ---@return table result `status` of the runner (of the calling shell with `caller_loop`), `left` in its TMPDIR once
  --- its Neovim's grandchild would have written, `ended` when the file's Neovim got to the end of its 2 second run,
  --- `runner_output` (stdout and stderr of the runner), `caller_output` of the calling shell, `caller_status` (the status
  --- of the runner that the calling shell printed with `caller_reports`), and `report`, one line with all of these but
  --- `ended` and `caller_status` for the message of an assertion
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
    if run.late_tee then
      write(dir .. "/tee.delay", { tostring(run.late_tee) })
    end
    if run.slow_rm then
      write(dir .. "/rm.slow", { tostring(run.slow_rm) })
    end
    if run.rm_fails then
      write(dir .. "/rm.fail", {})
    end
    local hold = run.hold or (run.during_rm == "launcher" or run.during_mv) and "start" or nil
    if hold then
      write(dir .. "/hold.sh", hold == "write" and HOLD_WRITE or HOLD_START)
    end
    if run.during_rm == "tee" then
      write(dir .. "/tee.hold", {})
    end
    if run.during_rm or run.rm_holds then
      write(dir .. "/rm.hold", {})
    end
    if run.second_signal then
      write(dir .. "/rm.second_signal", { run.second_signal })
    end
    if run.mv_fails then
      write(dir .. "/mv.fail", {})
    end
    if run.during_mv then
      write(dir .. "/mv.hold", {})
    end
    if run.write_before_kill then
      write(dir .. "/cat.hold", {})
      write(dir .. "/slow_spec.lua.write_on_cue", {})
    end
    if run.interrupt then
      write(dir .. "/" .. run.interrupt .. ".interrupt", { signal })
    end
    if run.interrupt_at then
      write(dir .. "/" .. run.interrupt .. ".at", { tostring(run.interrupt_at) })
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
    elseif run.caller_reports then
      job = "LC_ALL=C bash -c " .. quote('"$0" > ' .. quote(dir .. "/runner.out") .. " 2>&1; echo runner_status=$?")
      job = job .. " " .. quote(script) .. " > " .. quote(dir .. "/caller.out") .. " 2>&1"
    end
    local gate = run.window and "/slow_spec.lua.timeout_started"
      or hold and "/a.held"
      or run.during_rm == "tee" and "/tee.held"
      or "/slow_spec.lua.started"
    local send = ""
    if not run.interrupt then
      send = "for _ in $(seq 100); do [ -e " .. quote(dir .. gate) .. " ] && break; sleep 0.1; done; "
      send = send .. "kill -" .. signal .. " " .. target .. "; "
    end
    if run.during_mv then
      send = send .. "for _ in $(seq 100); do [ -e " .. quote(dir .. "/mv.held") .. " ] && break; sleep 0.1; done; "
      send = send .. ": > " .. quote(dir .. "/a.release") .. "; "
      send = send
        .. "for _ in $(seq 100); do [ -e "
        .. quote(dir .. "/slow_spec.lua.started")
        .. " ] && break; sleep 0.1; done; "
      send = send .. ": > " .. quote(dir .. "/mv.release") .. "; "
    end
    if run.write_before_kill then
      send = send .. "for _ in $(seq 100); do [ -e " .. quote(dir .. "/cat.held") .. " ] && break; sleep 0.1; done; "
      send = send .. ": > " .. quote(dir .. "/slow_spec.lua.cue") .. "; "
      send = send
        .. "for _ in $(seq 100); do [ -e "
        .. quote(dir .. "/slow_spec.lua.written")
        .. " ] && break; sleep 0.1; done; "
      send = send .. ": > " .. quote(dir .. "/cat.release") .. "; "
    end
    if run.during_rm then
      local release = run.during_rm == "tee" and "/tee.go" or "/a.release"
      send = send .. "for _ in $(seq 100); do [ -e " .. quote(dir .. "/rm.held") .. " ] && break; sleep 0.1; done; "
      send = send .. ": > " .. quote(dir .. release) .. "; sleep 1; : > " .. quote(dir .. "/rm.release") .. "; "
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
      .. (hold and " BASH_ENV=" .. quote(dir .. "/hold.sh") or "")
      .. "; set -m; "
      .. job
      .. " & pid=$!; "
      .. send
      .. "wait $pid 2> /dev/null; echo status=$?; "
      .. (hold and not run.during_rm and not run.during_mv and ": > " .. quote(dir .. "/a.release") .. "; " or "")
      .. "sleep 3"
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
    local status = output:match("status=(%d+)") or output
    return {
      status = status,
      left = left,
      ended = ended ~= nil,
      caller_output = caller_output,
      caller_status = caller_output:match("runner_status=(%d+)"),
      runner_output = runner_output,
      report = string.format(
        "status %s, left %q, caller output %q, runner output %q",
        status,
        left,
        caller_output,
        runner_output
      ),
    }
  end

  for _, case in ipairs({ { "SIGTERM", "TERM", "143" }, { "SIGINT", "INT", "130" } }) do
    local name, signal, expected_status = case[1], case[2], case[3]
    local description = "stops the running file and removes its temp files and folders on "
    it(description .. name .. " at once, and exits " .. expected_status, function()
      local result = signal_runner(signal, {})

      assert.are.equal(expected_status, result.status, result.report)
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

    assert.are.equal("143", result.status, result.report)
    assert.are.equal("", result.left, "a Neovim that ignores SIGTERM ran on after the runner died")
    assert.is_false(result.ended)
  end)

  it("leaves no exit status file when the file's subshell ends after the runner cleaned up", function()
    local result = signal_runner("TERM", { late_tee = 1 })

    assert.are.equal("143", result.status, result.report)
    assert.are.equal("", result.left, "the file's subshell wrote its exit statuses after the runner deleted its items")
    assert.is_nil(result.runner_output:find("No such file", 1, true), result.runner_output)
  end)

  it("opens no file after its cleanup started, even when its rm is slow and its tee ends late", function()
    -- The file's tee ends half a second after the signal, while the stub rm waits between its files and its folders.
    local result = signal_runner("TERM", { late_tee = 0.5, slow_rm = 1.5 })

    assert.are.equal("143", result.status, result.report)
    assert.are.equal("", result.left, "something made a file in a folder that the cleanup was removing")
    assert.is_nil(result.runner_output:find("Directory not empty", 1, true), result.runner_output)
  end)

  it("closes the status file for nvim and for tee, which only the file's subshell needs", function()
    if not has_proc_fd then
      pending("needs /proc/<pid>/fd to see which files a process holds open")
    end
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are.equal("0", status, output)
    assert.is_nil(io.open(dir .. "/a_spec.lua.holds_status_file"), "nvim kept the status file open")
    assert.is_nil(io.open(dir .. "/tee.holds_status_file"), "tee kept the status file open")
    assert.is_nil(io.open(dir .. "/rm.holds_status_file"), "the runner kept the status file open after it read it")
  end)

  it("uses no named descriptor redirection, which bash 3.2 does not know", function()
    local file = assert(io.open(script))
    local source = file:read("*a")
    file:close()

    for line in source:gmatch("[^\n]+") do
      if not line:match("^%s*#") then
        assert.is_nil(line:find("{[%a_][%w_]*}[<>]"), line)
      end
    end
  end)

  it("stops and does not pass when it cannot open the status file", function()
    write(dir .. "/mkdir.drop_state", {})
    local status, output, ran = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are_not.equal("0", status, output)
    assert.is_nil(output:find("All integration tests passed", 1, true), output)
    assert.are.same({}, ran)
  end)

  it("uses the exit status of the file's subshell when it cannot read the statuses back", function()
    -- The stub nvim deletes the state folder, where the statuses go, so the runner finds no file to read.
    write(dir .. "/tee.exit", { "3" })
    local status, output = run_script({
      { name = "gone_spec.lua", exit = 0, output = summary(2, 0, 0), remove_state = true },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("FAILED: gone_spec.lua: nvim exit 3\n", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - gone_spec.lua", 1, true), output)
  end)

  it("stops a file on SIGTERM that arrives after timeout started and before it made its process group", function()
    local result = signal_runner("TERM", { window = true })

    assert.are.equal("143", result.status, result.report)
    assert.are.equal("", result.left, "the runner left temp files or folders behind")
    assert.is_nil(io.open(dir .. "/slow_spec.lua.started"), "the file's Neovim started after the runner died")
  end)

  it("dies by SIGINT on Ctrl-C, so a shell that calls it in a loop stops the loop", function()
    local result = signal_runner("INT", { caller_loop = true })

    assert.are.equal("130", result.status, result.report)
    assert.are.equal("", result.caller_output, "the calling shell went on after the runner got Ctrl-C")
    assert.are.equal("", result.left, "the runner left temp files or folders behind")
    assert.is_false(result.ended)
  end)

  it("dies by SIGINT on Ctrl-C when its cleanup fails, so a shell that calls it in a loop stops the loop", function()
    local result = signal_runner("INT", { caller_loop = true, rm_fails = true })

    assert.are.equal("130", result.status, result.report)
    assert.are.equal("", result.caller_output, "the calling shell went on after the runner got Ctrl-C")
    assert.are.equal("", result.left, "the runner left temp files or folders behind")
    assert.is_false(result.ended)
  end)

  -- A second signal reaches the rm of the cleanup as well. The runner ignores the signals from the first line of its
  -- handler on, and its rm ignores them too, so the cleanup ends and the result is that of the first signal.
  for _, first in ipairs({ { "INT", "130" }, { "TERM", "143" }, { "HUP", "129" } }) do
    for _, second in ipairs({ "INT", "TERM", "HUP" }) do
      local signal, expected_status = first[1], first[2]
      it("finishes its cleanup and exits " .. expected_status .. " when " .. second .. " follows " .. signal, function()
        if signal_is_ignored(signal) then
          pending(signal .. " is ignored in this environment, so the runner ignores it too")
        end
        local result = signal_runner(signal, { second_signal = second })

        assert.are.equal(expected_status, result.status, result.report)
        assert.are.equal("", result.left, "the runner left the folder that its cleanup moved")
        local survived = io.open(dir .. "/rm.survived")
        assert.is_not_nil(survived, "the second " .. second .. " stopped the rm of the cleanup")
        survived:close()
      end)
    end
  end

  -- bash stops its own loop only for a child that died of SIGINT, so for SIGTERM and SIGHUP the sign of a runner that
  -- died of the signal, and did not exit with 143 or 129, is the report that bash prints for the child.
  for _, case in ipairs({ { "TERM", "143", "Terminated" }, { "HUP", "129", "Hangup" } }) do
    local signal, expected_status, report = case[1], case[2], case[3]
    it("dies of " .. signal .. " that it gets, so that the calling shell sees a child that was killed", function()
      if signal_is_ignored(signal) then
        pending(signal .. " is ignored in this environment, so the runner ignores it too")
      end
      local result = signal_runner(signal, { interrupt = "mkdir", caller_reports = true })

      assert.are.equal(expected_status, result.caller_status, result.report)
      assert.is_truthy(
        result.caller_output:find(report, 1, true),
        "the runner exited with " .. expected_status .. " and did not die of " .. signal .. ": " .. result.report
      )
      assert.are.equal("", result.left, "the runner left temp files or folders behind")
    end)
  end

  it("stops the Neovim that the shell of the file started while the cleanup renamed its folder", function()
    local result = signal_runner("INT", { during_mv = true })

    assert.are.equal("130", result.status, result.report)
    assert.are.equal("", result.left, "the file's Neovim ran on and wrote into the folder after the runner died")
    assert.is_false(result.ended, "the file's Neovim ran on after the runner died")
  end)

  it("removes what a live Neovim wrote into the old folder path after the cleanup moved the folder", function()
    local result = signal_runner("INT", { write_before_kill = true })

    assert.are.equal("130", result.status, result.report)
    assert.are.equal("", result.left, "the file's Neovim made a folder at the old path, and the cleanup left it")
    assert.is_false(result.ended)
  end)

  it("stops the file and removes its folder under the old name when the rename of the folder fails", function()
    local result = signal_runner("INT", { mv_fails = true })

    assert.are.equal("130", result.status, result.report)
    assert.are.equal("", result.left, "the runner left its folder, or its Neovim's grandchild ran on")
    assert.is_false(result.ended)
  end)

  it("leaves a folder alone that is named like its temp folder with .gone added", function()
    local work = dir .. "/tmp/fixed"
    shell("mkdir -p " .. quote(work .. ".gone") .. " && : > " .. quote(work .. ".gone/keep"))
    write(dir .. "/mktemp.name", { work })
    local result = signal_runner("INT", {})

    assert.are.equal("130", result.status, result.report)
    assert.are.equal("fixed.gone\n", result.left, "the runner left its folder, or removed the one that it did not make")
    assert.is_not_nil(io.open(work .. ".gone/keep"), "the cleanup removed a folder that it did not make")
    assert.is_false(result.ended)
  end)

  for _, case in ipairs({ { "mktemp", 1 }, { "mkdir", 1 }, { "mkdir", 2 } }) do
    local command, at = case[1], case[2]
    it(
      "removes its temp items when SIGINT comes right after its " .. command .. " number " .. at .. " made them",
      function()
        local result = signal_runner("INT", { interrupt = command, interrupt_at = command == "mkdir" and at or nil })

        assert.are.equal("130", result.status, result.report)
        assert.are.equal("", result.left, "the runner left a temp item that it made before it stored the name")
        assert.is_nil(io.open(dir .. "/ran"), "the file's Neovim started after the runner died")
      end
    )
  end

  for _, case in ipairs({ { "SIGTERM", "TERM", "143" }, { "SIGHUP", "HUP", "129" } }) do
    local name, signal, expected_status = case[1], case[2], case[3]
    for _, at in ipairs({ 1, 2 }) do
      it("removes its temp folder when " .. name .. " comes while its mkdir number " .. at .. " runs", function()
        if signal_is_ignored(signal) then
          pending(name .. " is ignored in this environment, so the runner ignores it too")
        end
        local result = signal_runner(signal, { interrupt = "mkdir", interrupt_at = at, rm_holds = at == 2 })

        assert.are.equal(expected_status, result.status, result.report)
        assert.are.equal("", result.left, "mkdir made a folder after the runner had cleaned up")
        assert.is_nil(io.open(dir .. "/ran"), "the file's Neovim started after the runner died")
      end)
    end
  end

  for _, case in ipairs({
    { "SIGTERM", "TERM", "143", "start" },
    { "SIGINT", "INT", "130", "start" },
    { "SIGINT", "INT", "130", "write" },
  }) do
    local name, signal, expected_status, hold = case[1], case[2], case[3], case[4]
    local where = hold == "start" and "before the shell of the file made its process id file"
      or "after the shell of the file made its process id file and before it wrote the id"
    it("starts no Neovim when " .. name .. " comes " .. where, function()
      local result = signal_runner(signal, { hold = hold })

      assert.are.equal(expected_status, result.status, result.report)
      assert.are.equal("", result.left, "the shell of the file made a file after the runner cleaned up")
      assert.is_nil(io.open(dir .. "/slow_spec.lua.started"), "the file's Neovim started after the runner died")
    end)
  end

  it("starts no Neovim when SIGINT comes while its rm has deleted the files and not yet the folders", function()
    local result = signal_runner("INT", { during_rm = "launcher" })

    assert.are.equal("130", result.status, result.report)
    assert.are.equal("", result.left, "the shell of the file made a file after the runner cleaned up")
    assert.is_nil(io.open(dir .. "/slow_spec.lua.started"), "the file's Neovim started while the runner cleaned up")
  end)

  for _, case in ipairs({ { "SIGTERM", "TERM", "143" }, { "SIGINT", "INT", "130" } }) do
    local name, signal, expected_status = case[1], case[2], case[3]
    it("leaves no output file when " .. name .. " comes before tee opened it and tee opens it during the rm", function()
      local result = signal_runner(signal, { during_rm = "tee" })

      assert.are.equal(expected_status, result.status, result.report)
      assert.are.equal("", result.left, "tee made its output file in the folder that the runner was removing")
    end)
  end

  it("starts no Neovim when the shell of the file cannot write its process id", function()
    write(dir .. "/mkdir.block_group", {})
    local status, output, ran = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are_not.equal("0", status, output)
    assert.are.same({}, ran)
  end)

  it("does not remove a folder that it did not make, when the name that mktemp printed exists", function()
    shell("mkdir " .. quote(dir .. "/taken") .. " && : > " .. quote(dir .. "/taken/keep"))
    write(dir .. "/mktemp.name", { dir .. "/taken" })
    local status, output, ran = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
    })

    assert.are_not.equal("0", status, output)
    assert.are.same({}, ran)
    assert.is_not_nil(io.open(dir .. "/taken/keep"), "the runner removed a folder that it did not make: " .. output)
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

  ---@param text string
  ---@param needle string
  ---@return integer
  local function occurrences(text, needle)
    local count, from = 0, 1
    while true do
      local found, last = text:find(needle, from, true)
      if not found then
        return count
      end
      count = count + 1
      from = last + 1
    end
  end

  for _, case in ipairs({
    { 139, ", SIGSEGV" },
    { 134, ", SIGABRT" },
    { 130, ", SIGINT" },
    { 129, ", SIGHUP" },
    { 1, "" },
  }) do
    local exit_status, note = case[1], case[2]
    it("names the exit status of a nvim that fails with " .. exit_status .. " after a clean summary", function()
      local status, output = run_script({
        { name = "crash_after_spec.lua", exit = exit_status, output = summary(3, 0, 0) },
      })

      assert.are.equal("1", status, output)
      assert.is_truthy(
        output:find("FAILED: crash_after_spec.lua: nvim exit " .. exit_status .. note .. "\n", 1, true),
        output
      )
      assert.are.equal(1, occurrences(output, "FAILED:"), output)
      assert.is_truthy(output:find("Total Success: 3", 1, true), output)
      assert.is_truthy(output:find("Failed test files:\n  - crash_after_spec.lua", 1, true), output)
    end)
  end

  it("names the signal in the line of a file whose nvim crashed before any summary", function()
    local status, output = run_script({
      { name = "crash_spec.lua", exit = 139, output = hung_output("crash_spec.lua") },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(
      output:find("FAILED: crash_spec.lua: no plenary summary (nvim exit 139, SIGSEGV)", 1, true),
      output
    )
    assert.are.equal(1, occurrences(output, "FAILED:"), output)
    assert.is_nil(output:find("TIMEOUT", 1, true), output)
  end)

  it("names SIGKILL in the TIMEOUT line of a nvim that was killed, which the limit may not have done", function()
    local status, output = run_script({
      { name = "oom_spec.lua", exit = 0, output = hung_output("oom_spec.lua"), die_by = "KILL" },
    })

    local _, limit = timeout_limits()
    assert.are.equal("1", status, output)
    assert.is_truthy(
      output:find(
        "TIMEOUT: oom_spec.lua was stopped (exit 137, SIGKILL): nvim did not exit within "
          .. limit
          .. "s, or another process killed it",
        1,
        true
      ),
      output
    )
    assert.are.equal(1, occurrences(output, "TIMEOUT:"), output)
    assert.is_truthy(output:find("Failed test files:\n  - oom_spec.lua", 1, true), output)
  end)

  it("prints one line with a reason for a nvim that was killed after a clean summary", function()
    local status, output = run_script({
      { name = "oom_after_spec.lua", exit = 0, output = summary(2, 0, 0), die_by = "KILL" },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("TIMEOUT: oom_after_spec.lua was stopped (exit 137, SIGKILL)", 1, true), output)
    assert.is_nil(output:find("FAILED:", 1, true), output)
  end)

  it("names tee, not nvim, when tee fails after a clean summary", function()
    write(dir .. "/tee.exit", { "3" })
    local status, output = run_script({
      { name = "tee_spec.lua", exit = 0, output = summary(2, 0, 0) },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("FAILED: tee_spec.lua: tee exit 3\n", 1, true), output)
    assert.is_nil(output:find("nvim exit", 1, true), output)
    assert.is_truthy(output:find("Failed test files:\n  - tee_spec.lua", 1, true), output)
  end)

  it("names both stages when nvim and tee fail", function()
    write(dir .. "/tee.exit", { "141" })
    local status, output = run_script({
      { name = "both_spec.lua", exit = 1, output = summary(2, 0, 0) },
    })

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("FAILED: both_spec.lua: nvim exit 1\n", 1, true), output)
    assert.is_truthy(output:find("FAILED: both_spec.lua: tee exit 141, SIGPIPE\n", 1, true), output)
    assert.are.equal(2, occurrences(output, "FAILED:"), output)
  end)

  it("words the TIMEOUT line so that it holds when an outside SIGTERM reached timeout", function()
    local status, output = run_script({
      { name = "outside_spec.lua", exit = 0, output = hung_output("outside_spec.lua"), outside_term = true },
    })

    local _, limit = timeout_limits()
    assert.are.equal("1", status, output)
    -- uutils timeout answers an outside SIGTERM with 124, GNU timeout with 143.
    local code, text = output:match("TIMEOUT: outside_spec.lua was stopped %(exit (%d+)%): ([^\n]*)\n")
    assert.is_truthy(code == "124" or code == "143", output)
    assert.is_truthy(text, output)
    assert.are.equal("nvim did not exit within " .. limit .. "s, or an outside signal stopped it", text)
    assert.are.equal(1, occurrences(output, "TIMEOUT:"), output)
  end)

  it("leaves no temp item behind after a file that failed, the exit status file included", function()
    write(dir .. "/tee.exit", { "3" })
    shell("mkdir -p " .. quote(dir .. "/tmp"))
    local status, output = run_script({
      { name = "a_spec.lua", exit = 0, output = summary(1, 0, 0) },
      { name = "b_spec.lua", exit = 139, output = summary(1, 0, 0) },
    }, nil, dir .. "/tmp")

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("FAILED: b_spec.lua: nvim exit 139, SIGSEGV\n", 1, true), output)
    local listing = assert(io.popen("ls -A " .. quote(dir .. "/tmp")))
    local left = listing:read("*a")
    listing:close()
    assert.are.equal("", left, "the runner left temp items behind")
  end)

  it("kills what the file left running when its nvim died by a signal before any summary", function()
    local status, output = run_script({
      { name = "segv_orphan_spec.lua", exit = 139, output = hung_output("segv_orphan_spec.lua"), orphan = true },
    })
    local pid_file = assert(io.open(dir .. "/segv_orphan_spec.lua.orphan.pid"))
    orphan_pid = pid_file:read("*l")
    pid_file:close()

    assert.are.equal("1", status, output)
    assert.is_truthy(output:find("no plenary summary (nvim exit 139, SIGSEGV)", 1, true), output)
    wait_until_stopped(orphan_pid)
    assert.is_false(is_running(orphan_pid), "the process the file left running was killed")
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
    assert.is_truthy(output:find("TIMEOUT: stuck_spec.lua was stopped (exit 137, SIGKILL)", 1, true), output)
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

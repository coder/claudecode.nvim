#!/bin/bash

# Script to run integration tests individually to avoid plenary test_directory hanging
# Each test file is run separately with test_file

set -e
# pipefail: don't let `tee` mask a failing nvim in the pipe below
set -o pipefail

# How long timeout lets one file's nvim run. plenary's test_file ends a file at 50s on its own: exit 1, no TIMEOUT
# line, and its nvim left running. So this limit plus the 5s kill grace below must stay under 50s.
# selection_held_spec.lua sleeps 21.6s in 77 vim.wait calls, so 30s left each of them 0.1s of slack under load.
FILE_TIMEOUT=40s

# The temp folder of the file that runs, and the file in it that holds the process id of its `timeout` while it runs. The
# cleanup stops the file's Neovims before it removes the folder, because one that ends later writes ShaDa and makes its
# state folder again. It kills `timeout` itself first: until timeout has made its own group, no Neovim runs yet. It
# uses KILL for both, because with `timeout` dead its -k grace never starts, and a Neovim that ignores TERM would run
# on.
# The cleanup moves the folder into a new folder next to it, the grave, before it reads the process id file, so the old
# path is gone at once. The grave comes from `mktemp -d`, so a name that exists already, as a folder of the user, is not
# the target of the move. When the grave or the move fails, the folder keeps its old name, and the cleanup works there.
# The shell that starts the Neovim writes its process id to the file at the old path, then looks for the folder at the
# old path (the `bash -c` line in run_test_file). So one of them sees the other: a shell that wrote its id too late for
# the cleanup to read it finds no folder, and starts no Neovim. A Neovim that still runs between the move and the kill
# can make its state folder at the old path again, so the last rm removes the old path as well.
CURRENT_WORK=""
CURRENT_FILE_RUNS=""
# shellcheck disable=SC2329 # The traps below run it.
cleanup_current_file() {
  local grave moved timeout_pid
  [[ -n $CURRENT_WORK ]] || return 0
  moved=$CURRENT_WORK
  grave=$(mktemp -d "$CURRENT_WORK.XXXXXX" 2>/dev/null) || grave=""
  if [[ -n $grave ]] && mv "$CURRENT_WORK" "$grave/work" 2>/dev/null; then
    moved=$grave/work
  fi
  if [[ -n $CURRENT_FILE_RUNS && -s $moved/group ]]; then
    timeout_pid=$(cat "$moved/group")
    kill -KILL "$timeout_pid" 2>/dev/null || true
    kill -KILL -- "-$timeout_pid" 2>/dev/null || true
  fi
  rm -rf "$moved" ${grave:+"$grave"} "$CURRENT_WORK"
}
# A signal reaches the runner's own process group, and timeout leaves that group, so the file runs in the background and
# `wait` below returns at once when a trap runs. Bash runs a trap after the foreground command that it waits for, so a
# signal that comes while mkdir makes the folder finds the folder. The handler cleans up, then kills the runner with the
# signal, not with `exit`: a calling shell stops its own loop after a child that died by SIGINT, and goes on after one
# that exited 130. A cleanup that fails, such as an rm that cannot remove a folder, must not end the handler early
# either: with set -e the runner would exit with 1 before the kill, and the calling shell would go on. The handler
# ignores INT, TERM and HUP from its first line on, and so does its rm: a second Ctrl-C reaches the rm too and stops it
# half way, and bash 3.2 (the macOS /bin/bash) then dies with 130 and leaves the renamed folder.
# shellcheck disable=SC2329 # The traps below run it.
die_by_signal() {
  trap '' INT TERM HUP
  cleanup_current_file || true
  trap - EXIT INT TERM HUP
  kill -"$1" $$
  exit "$2"
}
trap cleanup_current_file EXIT
trap 'die_by_signal INT 130' INT
trap 'die_by_signal TERM 143' TERM
trap 'die_by_signal HUP 129' HUP

echo "=== Running Integration Tests Individually ==="

# Track overall results
TOTAL_SUCCESS=0
TOTAL_FAILED=0
TOTAL_ERRORS=0
FAILED_FILES=()

# The signal behind an exit status above 128, as ", SIGSEGV". Nothing for any other status.
signal_note() {
  local name
  if [[ $1 -gt 128 ]] && name=$(kill -l $(($1 - 128)) 2>/dev/null) && [[ -n $name ]]; then
    printf ', SIG%s' "$name"
  fi
}

# Function to run a single test file
run_test_file() {
  local test_file=$1
  local basename
  basename=$(basename "$test_file")

  echo ""
  echo "Running: $basename"

  # All temp items of the file live in one folder. The runner picks the name of the folder and stores it before it makes
  # the folder, so that no signal finds a folder that the runner made but does not know yet. `mktemp -u` makes nothing
  # and prints a random name. mkdir fails when that name exists, and the runner then drops the name. Only a signal that
  # comes before it drops the name can make it remove a folder that it did not make.
  local work_dir temp_output group_file state_dir config_dir tmp_dir status_file
  work_dir=$(mktemp -u)
  # A Neovim binds its socket at $work_dir/tmp/nvim.<pid>.<n>, which is at most 20 characters more than the work folder.
  # A socket path over 107 bytes is cut by libuv, and the cut name can be a file in the developer's TMPDIR, outside the
  # work folder. So a work folder with a name over 80 characters goes to /tmp, where its name is short.
  if [[ ${#work_dir} -gt 80 && -d /tmp && -w /tmp ]]; then
    work_dir=$(mktemp -u /tmp/tmp.XXXXXXXXXX)
  fi
  CURRENT_WORK=$work_dir
  mkdir -m 700 "$work_dir" || {
    CURRENT_WORK=""
    false
  }
  temp_output=$work_dir/output
  group_file=$work_dir/group
  state_dir=$work_dir/state
  config_dir=$work_dir/config
  tmp_dir=$work_dir/tmp
  status_file=$state_dir/exit_statuses
  mkdir -m 700 "$state_dir" "$config_dir" "$tmp_dir"
  CURRENT_FILE_RUNS=1
  exec 9>"$status_file"

  # timeout runs nvim in a process group named after its own pid, which is this shell's pid until it execs timeout.
  # plenary's test_file takes no options, so the Neovim it starts for a spec gets no -u and would read the developer's
  # init file. Without -u, Neovim runs $VIMINIT instead, so VIMINIT runs tests/minimal_init.lua, by an absolute path
  # in a variable so a path with a space or % needs no escaping. VIMINIT and the variable reach every process the spec
  # starts, and a Neovim there without -u runs minimal_init.lua too. The Neovim started here has -u.
  # State and config folders in temp folders keep a run out of ~/.local/state/nvim (ShaDa, log, swap files) and out of
  # the developer's ftplugin and after files. plenary lives under XDG_DATA_HOME, which stays. Both Neovims share the
  # folders, so the one started here takes -i NONE: two ShaDa writers made the first fail with E886 after a timeout.
  # TMPDIR and XDG_RUNTIME_DIR name the temp folder in the work folder: a Neovim that the cleanup kills does not remove
  # its socket folder, and the folder goes away with the work folder instead of staying in the developer's TMPDIR.
  # The file runs in the background and the runner waits for it: `wait` ends at once when the INT trap runs. The
  # subshell has no pipefail, because with it bash prints a job report ("Killed", two lines) when the cleanup above
  # kills `timeout`. It writes the exit statuses of nvim and of `tee` to a file in the state folder, so that the reason
  # line can name the stage that failed, and exits with the status of nvim, or with that of `tee` when nvim exited 0.
  # The runner opens that file as descriptor 9 before it starts the subshell, and the subshell writes to it. A subshell
  # that ends while the cleanup above removes the folder opens no path, so it cannot make a file in a folder that is
  # being removed. The subshell closes descriptor 9 for nvim and `tee`, which do not need it. The number is fixed,
  # because bash 3.2 (the macOS /bin/bash) does not know a `{name}>` redirection: it fails the `exec`, and with an EXIT
  # trap set it then exits 0 without running a spec.
  (
    set +o pipefail
    set +e
    VIMINIT='lua local f = vim.env.CLAUDECODE_MINIMAL_INIT if f then dofile(f) end' \
      CLAUDECODE_MINIMAL_INIT="$PWD/tests/minimal_init.lua" \
      XDG_STATE_HOME="$state_dir" XDG_CONFIG_HOME="$config_dir" TMPDIR="$tmp_dir" XDG_RUNTIME_DIR="$tmp_dir" \
      bash -c 'echo $$ 2> /dev/null > "$1" && [ -d "$2" ] || exit 1; shift 2; exec timeout -k 5s "$@"' \
      _ "$group_file" "$work_dir" "$FILE_TIMEOUT" \
      nvim --headless -i NONE -u tests/minimal_init.lua \
      -c "lua require('plenary.test_harness').test_file('$test_file')" \
      9>&- 2>&1 | tee "$temp_output" 9>&-
    pipe_status=("${PIPESTATUS[@]}")
    echo "${pipe_status[0]} ${pipe_status[1]}" >&9
    exit $((pipe_status[0] != 0 ? pipe_status[0] : pipe_status[1]))
  ) &
  if wait $!; then
    EXIT_CODE=0
  else
    EXIT_CODE=$?
  fi
  CURRENT_FILE_RUNS=""
  exec 9>&-
  local tee_status=0 status_line
  if status_line=$(cat "$status_file" 2>/dev/null) && [[ $status_line =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
    EXIT_CODE=${BASH_REMATCH[1]}
    tee_status=${BASH_REMATCH[2]}
  fi

  # Parse results from output
  local clean_output
  clean_output=$(sed 's/\x1b\[[0-9;]*m//g' "$temp_output")
  local success_count failed_count error_count
  success_count=$(echo "$clean_output" | grep "^Success:" | tail -1 | awk '{print $2}' || true)
  failed_count=$(echo "$clean_output" | grep "^Failed :" | tail -1 | awk '{print $3}' || true)
  error_count=$(echo "$clean_output" | grep "^Errors :" | tail -1 | awk '{print $3}' || true)

  # Plenary prints its summary only after it has run the whole file. Without all three counts, nvim stopped early,
  # whatever its exit code says. A count that is not 0 or 1 to 9 digits without a leading zero would stop bash or wrap
  # in the arithmetic below. The digits are spelled out because [0-9] also matches other digits in some locales.
  local plain_count='^(0|[123456789][0123456789]{0,8})$'
  local reason_printed=false
  if [[ ! $success_count =~ $plain_count ]] || [[ ! $failed_count =~ $plain_count ]] || [[ ! $error_count =~ $plain_count ]]; then
    echo "FAILED: $basename: no plenary summary (nvim exit $EXIT_CODE$(signal_note "$EXIT_CODE"))"
    reason_printed=true
    success_count=0
    failed_count=0
    error_count=1
  fi

  # Update totals
  TOTAL_SUCCESS=$((TOTAL_SUCCESS + success_count))
  TOTAL_FAILED=$((TOTAL_FAILED + failed_count))
  TOTAL_ERRORS=$((TOTAL_ERRORS + error_count))

  # Exit 124 is timeout's, 137 is its SIGKILL after 5 more seconds, and 143 is SIGTERM.
  # An outside SIGTERM that reaches timeout gives 124 (uutils), or 143 (GNU) when the child dies of it, and the
  # out-of-memory killer gives 137 like timeout's own KILL, so these lines do not claim that the limit was hit.
  if [[ $EXIT_CODE -eq 124 ]] || [[ $EXIT_CODE -eq 137 ]] || [[ $EXIT_CODE -eq 143 ]]; then
    if [[ $EXIT_CODE -eq 137 ]]; then
      echo "TIMEOUT: $basename was stopped (exit 137, SIGKILL): nvim did not exit within $FILE_TIMEOUT," \
        "or another process killed it"
    else
      echo "TIMEOUT: $basename was stopped (exit $EXIT_CODE): nvim did not exit within $FILE_TIMEOUT," \
        "or an outside signal stopped it"
    fi
    reason_printed=true
  fi

  # nvim busy in a Lua loop ignores SIGTERM and outlives timeout, and when the nvim started here died, the one that
  # plenary started for the spec runs on.
  if [[ $EXIT_CODE -ne 0 ]]; then
    kill -KILL -- "-$(cat "$group_file" 2>/dev/null)" 2>/dev/null || true
  fi

  # A file whose nvim exited non-zero gets a line with a reason: the no-summary line, the TIMEOUT line, or this one. A
  # file with no summary and a status of 124, 137 or 143 gets the first two.
  if [[ $EXIT_CODE -ne 0 ]] && [[ $reason_printed == false ]]; then
    echo "FAILED: $basename: nvim exit $EXIT_CODE$(signal_note "$EXIT_CODE")"
  fi
  if [[ $tee_status -ne 0 ]]; then
    echo "FAILED: $basename: tee exit $tee_status$(signal_note "$tee_status")"
  fi

  # Check if test failed
  if [[ $failed_count -gt 0 ]] || [[ $error_count -gt 0 ]] || [[ $EXIT_CODE -ne 0 ]] || [[ $tee_status -ne 0 ]]; then
    FAILED_FILES+=("$basename")
  fi

  # Cleanup
  rm -rf "$work_dir"
  CURRENT_WORK=""
}

for test_file in tests/integration/*_spec.lua; do
  run_test_file "$test_file"
done

# Summary
echo ""
echo "========================================="
echo "Integration Test Summary"
echo "========================================="
echo "Total Success: $TOTAL_SUCCESS"
echo "Total Failed: $TOTAL_FAILED"
echo "Total Errors: $TOTAL_ERRORS"

if [[ ${#FAILED_FILES[@]} -gt 0 ]]; then
  echo ""
  echo "Failed test files:"
  for file in "${FAILED_FILES[@]}"; do
    echo "  - $file"
  done
fi

# Exit with appropriate code
if [[ ${#FAILED_FILES[@]} -eq 0 ]]; then
  echo ""
  echo "✅ All integration tests passed!"
  exit 0
else
  echo ""
  echo "❌ Some integration tests failed!"
  exit 1
fi

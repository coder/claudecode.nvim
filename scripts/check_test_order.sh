#!/usr/bin/env bash
# check_test_order.sh [dir...]: fail when a spec registers tests (it, describe, pending) inside a `for ... in pairs()`
# loop. LuaJIT seeds its string hash per process, so pairs() visits string keys in a different order in each run, and
# `BUSTED_SEED=<seed> mise run test` would not repeat the test order. Register table-driven tests from an array with
# ipairs instead. The check relies on StyLua's indentation: a loop ends at the first `end` at the indentation of its
# `for`. Default dir: tests.
set -euo pipefail
(($#)) || set -- tests
find "$@" -name '*.lua' -type f -print0 | xargs -0 awk '
  FNR == 1 { loop_indent = "" }
  { match($0, /^[ \t]*/); indent = substr($0, 1, RLENGTH) }
  loop_indent == "" && /^[ \t]*for .* in pairs\(/ && !/[ \t]end$/ { loop_indent = indent; loop_line = FNR; next }
  loop_indent != "" && $0 == loop_indent "end" { loop_indent = ""; next }
  loop_indent != "" && /^[ \t]*(it|describe|pending)\(/ {
    print FILENAME ":" loop_line ": registers tests in pairs() order, which differs between runs; loop over an array with ipairs"
    found = 1
    loop_indent = ""
  }
  END { exit found }
'

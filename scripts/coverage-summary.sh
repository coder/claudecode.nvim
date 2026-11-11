#!/bin/bash

set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: coverage-summary.sh <luacov.report.out> <checkout folder>" >&2
  exit 64
fi

report=$1
root=${2%/}/

if [ ! -r "$report" ]; then
  echo "coverage-summary.sh: cannot read $report" >&2
  exit 2
fi

awk -v root="$root" '
  function emoji(percent) {
    if (percent + 0 >= 90) return "🟢"
    if (percent + 0 >= 70) return "🟡"
    return "🔴"
  }
  /^Summary$/ { in_summary = 1; next }
  !in_summary || $NF !~ /^[0-9.]+%$/ { next }
  {
    file = $0
    sub(/[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+[0-9.]+%[ \t]*$/, "", file)
    if (index(file, root) == 1) file = substr(file, length(root) + 1)
    if (file == "Total") {
      overall = $NF
    } else if (file in seen) {
      if (repeated++ == 0) first_repeated = file
    } else {
      seen[file] = 1
      rows = rows "| `" file "` | " emoji($NF) " " $NF " |\n"
      count++
    }
  }
  END {
    print "## 📊 Test Coverage Report\n"
    if (count == 0 || overall == "") {
      print "❌ luacov.report.out has no per-file row or no Total row"
      exit 1
    }
    if (repeated > 0) {
      print "❌ luacov.report.out repeats a path (" repeated " extra rows, first `" first_repeated "`). Check `modules` in .luacov."
      exit 1
    }
    print "**Overall Coverage: " overall "**\n"
    print "| File | Coverage |"
    print "|------|----------|"
    printf "%s", rows
  }
' "$report"

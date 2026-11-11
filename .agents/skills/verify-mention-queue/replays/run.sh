#!/usr/bin/env bash
# Replay each path that once broke a rule, against the real plugin in a fresh headless Neovim.
# Usage: replays/run.sh [NAME...]   (default: every *.lua replay except lib.lua and sync.lua)
# NVIM overrides the Neovim binary. Each replay's full timeline goes to $OUT/<name>.log (OUT defaults to a new
# mktemp -d dir, printed first). Prints one verdict line per replay (KEPT or BROKEN, and the rule) and a count line.
# Exits 0 when every replay kept its promise, 1 otherwise.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
NVIM=${NVIM:-nvim}
OUT=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/mention-replays.XXXXXX")}
echo "logs: $OUT"
names=("$@")
if ((${#names[@]} == 0)); then
  for f in "$here"/*.lua; do
    case $(basename "$f") in lib.lua | sync.lua) ;; *) names+=("$(basename "$f" .lua)") ;; esac
  done
fi
kept=0
for name in "${names[@]}"; do
  run="$OUT/$name.run"
  mkdir -p "$run/xdg-config" "$run/xdg-data" "$run/xdg-state" "$run/xdg-cache" "$run/claude" "$run/cwd"
  (cd "$run/cwd" && XDG_CONFIG_HOME="$run/xdg-config" XDG_DATA_HOME="$run/xdg-data" XDG_STATE_HOME="$run/xdg-state" \
    XDG_CACHE_HOME="$run/xdg-cache" CLAUDE_CONFIG_DIR="$run/claude" timeout 120 \
    "$NVIM" --headless -u NONE -i NONE --cmd "set rtp^=$repo" -l "$here/$name.lua") >"$OUT/$name.log" 2>&1
  verdict=$(grep -E '^(KEPT|BROKEN) ' "$OUT/$name.log" | tail -1)
  [[ -n $verdict ]] || verdict="BROKEN $name: the replay printed no verdict (see $OUT/$name.log)"
  [[ $verdict == KEPT* ]] && kept=$((kept + 1))
  echo "$name: $verdict"
done
echo "$kept of ${#names[@]} replays kept their promise"
((kept == ${#names[@]}))

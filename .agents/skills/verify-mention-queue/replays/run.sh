#!/usr/bin/env bash
# Replay each path that once broke a rule, against the real plugin in a fresh headless Neovim.
# Usage: replays/run.sh [NAME...]   (default: every *.lua replay except lib.lua and sync.lua)
# NVIM overrides the Neovim binary. Each replay's full timeline goes to $OUT/<name>.log (OUT defaults to a new
# mktemp -d dir, printed first). Prints one verdict line per replay (KEPT or BROKEN, and the rule) and a count line.
# A replay is KEPT only when it printed KEPT and its Neovim exited 0.
# Exits 0 when every replay kept its promise, 1 otherwise.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
NVIM=${NVIM:-nvim}
OUT=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/mention-replays.XXXXXX")}
# Each replay runs from its own cwd, so a relative OUT or NVIM must become absolute first.
mkdir -p "$OUT" && OUT=$(cd "$OUT" && pwd) || exit 2
if [[ $NVIM == */* ]] && nvim_dir=$(cd "$(dirname "$NVIM")" 2>/dev/null && pwd); then
  NVIM=$nvim_dir/$(basename "$NVIM")
fi
command -v "$NVIM" >/dev/null || {
  echo "ERROR: no Neovim at $NVIM (set NVIM=<path to nvim>)" >&2
  exit 2
}
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
  # macOS has no `timeout`, so perl's alarm bounds the run. REPLAY_REPO and REPLAY_SCRIPT reach Neovim through the
  # environment, so a checkout path with a space or another Ex-special character still works. `nvim -l` needs
  # Neovim 0.9, so the replay runs through :luafile, as in .github/workflows/test.yml. A replay quits Neovim at its
  # verdict. If it raises before that, the last -c exits 2. The group's stderr takes bash's own note of a Neovim that
  # a signal ended ("Alarm clock"), so it lands in the replay's log, not on the terminal.
  { (cd "$run/cwd" && XDG_CONFIG_HOME="$run/xdg-config" XDG_DATA_HOME="$run/xdg-data" XDG_STATE_HOME="$run/xdg-state" \
    XDG_CACHE_HOME="$run/xdg-cache" CLAUDE_CONFIG_DIR="$run/claude" \
    REPLAY_REPO="$repo" REPLAY_SCRIPT="$here/$name.lua" \
    perl -e 'alarm 120; exec @ARGV' "$NVIM" --headless -u NONE -i NONE \
    --cmd 'lua vim.opt.rtp:prepend(vim.env.REPLAY_REPO)' -c 'execute "luafile" fnameescape($REPLAY_SCRIPT)' \
    -c 'cquit 2') >"$OUT/$name.log" 2>&1; } 2>>"$OUT/$name.log"
  rc=$?
  verdict=$(grep -E '^(KEPT|BROKEN) ' "$OUT/$name.log" | tail -1)
  if [[ -z $verdict ]]; then
    verdict="BROKEN $name: the replay printed no verdict, and Neovim exited $rc (see $OUT/$name.log)"
  elif ((rc != 0)); then
    # A verdict, then a failed exit (for example the alarm): the run failed whatever the verdict said.
    verdict="BROKEN $name: Neovim exited $rc after the verdict \"$verdict\" (see $OUT/$name.log)"
  fi
  [[ $verdict == KEPT* ]] && kept=$((kept + 1))
  echo "$name: $verdict"
done
echo "$kept of ${#names[@]} replays kept their promise"
((kept == ${#names[@]}))

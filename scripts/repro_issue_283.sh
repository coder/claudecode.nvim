#!/usr/bin/env bash
# Reproduction / verification for issue #283:
#   "find_available_port probe-then-rebind races; create_server has no retry ->
#    EADDRINUSE with parallel Neovim instances (regression in #282)"
#   https://github.com/coder/claudecode.nvim/issues/283
#
# Drives three checks against the REAL plugin code:
#
#   Part 1 - REGRESSION TRIGGER (lost RNG seeding): runs the port selector in
#            several fresh Neovim processes and asserts they ALL pick the same
#            port. Pre-#282 this varied per process (shuffle_array seeded the
#            PRNG via os.time()); post-#282 it is deterministic, so every
#            instance collides.
#
#   Part 2 - MECHANISM (broken probe + listen-time EADDRINUSE): the in-process
#            proof from repro_issue_283.lua (mechanism mode).
#
#   Part 3 - END-TO-END: two real plugin servers (create_server). Instance A
#            listens; Instance B fails with the user's exact error,
#            "Failed to listen on port <P>: EADDRINUSE", on the SAME port.
#
# Usage (from repo root):
#   scripts/repro_issue_283.sh
#   NVIM=/path/to/nvim scripts/repro_issue_283.sh   # to pin a Neovim binary
#
# Exit code: 1 if #283 reproduces (deterministic collision + B fails), else 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUA="$SCRIPT_DIR/repro_issue_283.lua"
NVIM="${NVIM:-nvim}"

if ! command -v "$NVIM" >/dev/null 2>&1; then
  echo "ERROR: nvim not found (set NVIM=/path/to/nvim)" >&2
  exit 2
fi

WORK="$(mktemp -d)"
A_OUT="$WORK/a.out"
A_PID=""
# shellcheck disable=SC2329  # invoked indirectly via `trap cleanup EXIT` below
cleanup() {
  [ -n "$A_PID" ] && kill "$A_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

run_port() {
  REPRO283_MODE=port "$NVIM" --headless -u NONE -l "$LUA" 2>/dev/null |
    tr -d '\r' | sed -n 's/^SELECTED_PORT=//p'
}

echo "############################################################"
echo "# issue #283 reproduction"
echo "# nvim: $("$NVIM" --version | head -1)"
echo "############################################################"

#############################################
# Part 1: cross-process determinism
#############################################
echo
echo "=== Part 1: is port selection deterministic across fresh processes? ==="
P1="$(run_port)"
P2="$(run_port)"
P3="$(run_port)"
echo "  fresh process #1 -> $P1"
echo "  fresh process #2 -> $P2"
echo "  fresh process #3 -> $P3"
DETERMINISTIC=0
if [ -n "$P1" ] && [ "$P1" = "$P2" ] && [ "$P2" = "$P3" ]; then
  DETERMINISTIC=1
  echo "  RESULT: DETERMINISTIC -- every fresh Neovim picks port $P1 (regression: lost RNG seeding)"
else
  echo "  RESULT: varies across processes (RNG appears seeded)"
fi

#############################################
# Part 2: in-process mechanism proof
#############################################
echo
echo "=== Part 2: broken probe + listen-time EADDRINUSE (in-process) ==="
"$NVIM" --headless -u NONE -l "$LUA"
MECH_RC=$?
echo "  (mechanism script exit code: $MECH_RC; 1 = reproduced)"

#############################################
# Part 3: two real instances, end-to-end
#############################################
echo
echo "=== Part 3: two real plugin servers in parallel ==="
REPRO283_MODE=serve REPRO283_LABEL=A REPRO283_WAIT_MS=8000 \
  "$NVIM" --headless -u NONE -l "$LUA" >"$A_OUT" 2>&1 &
A_PID=$!

# Wait until A reports its listening port.
A_LINE=""
for _ in $(seq 1 80); do
  A_LINE="$(tr -d '\r' <"$A_OUT" | sed -n 's/.*\(INSTANCE_A: .*\)/\1/p')"
  [ -n "$A_LINE" ] && break
  sleep 0.1
done
echo "  A: ${A_LINE:-<no output>}"

B_OUT="$(REPRO283_MODE=serve REPRO283_LABEL=B REPRO283_WAIT_MS=200 \
  "$NVIM" --headless -u NONE -l "$LUA" 2>&1 | tr -d '\r' | sed -n 's/.*\(INSTANCE_B: .*\)/\1/p')"
echo "  B: ${B_OUT:-<no output>}"

A_PORT="$(printf '%s' "$A_LINE" | sed -n 's/.*LISTENING port=\([0-9]*\).*/\1/p')"
E2E=0
if printf '%s' "$B_OUT" | grep -q "Failed to listen on port .*EADDRINUSE"; then
  B_PORT="$(printf '%s' "$B_OUT" | sed -n 's/.*Failed to listen on port \([0-9]*\).*/\1/p')"
  if [ -n "$A_PORT" ] && [ "$A_PORT" = "$B_PORT" ]; then
    E2E=1
    echo "  RESULT: B failed with EADDRINUSE on the SAME port A holds ($A_PORT)"
  else
    echo "  RESULT: B failed with EADDRINUSE but on port $B_PORT (A holds $A_PORT)"
    E2E=1
  fi
else
  echo "  RESULT: B did NOT collide (started on a different port)"
fi

#############################################
# Verdict
#############################################
echo
echo "=== VERDICT ==="
if [ "$DETERMINISTIC" -eq 1 ] && [ "$MECH_RC" -eq 1 ] && [ "$E2E" -eq 1 ]; then
  echo "#283 REPRODUCED: parallel Neovim instances deterministically pick the same"
  echo "port ($P1); the probe cannot detect the active listener; create_server fails"
  echo "at listen() with EADDRINUSE and no retry."
  exit 1
else
  echo "#283 NOT fully reproduced on this environment:"
  echo "  deterministic port = $DETERMINISTIC, mechanism = $((MECH_RC == 1 ? 1 : 0)), end-to-end = $E2E"
  echo "(After a fix that seeds the RNG + retries on EADDRINUSE, Part 1 should vary"
  echo " and Part 3's instance B should start on a different port.)"
  exit 0
fi

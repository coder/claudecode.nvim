#!/usr/bin/env bash
# Fake "Claude" CLI used to reproduce issue #232 without a real Claude session.
#
# It prints a long block of numbered output (so there is genuine scrollback to
# lose) and then drops into `cat`, which keeps the job alive with a prompt-like
# bottom line. That is all the reproduction needs: a live terminal buffer whose
# cursor/PTY lives at the BOTTOM, while the user reads near the TOP in Normal
# mode.
for i in $(seq 1 200); do
  printf 'claude output line %03d ........................................\n' "$i"
done
printf '\n--- END OF OUTPUT (scroll UP to read from line 001) ---\n'
printf '> '
exec cat

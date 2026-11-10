#!/usr/bin/env python3
"""Synthetic Claude-style TUI used to instrument the climbing-cursor bug (#240).

It does what a modern TUI does on startup: enables focus reporting (DECSET 1004),
bracketed paste (2004) and DSR-style cursor queries, then logs every byte it
receives from the PTY plus every SIGWINCH. The goal is to discover what Neovim
sends to the inner program when the Snacks Claude window is hidden and re-shown
(no real resize was observed), so we can explain why Claude re-renders and the
cursor climbs.

Log path: $CURSOR_REPRO_BOX_LOG (default /tmp/box.log).
"""
import os
import sys
import time
import signal
import termios
import tty
import select

LOG = os.environ.get("CURSOR_REPRO_BOX_LOG", "/tmp/box.log")
_seq = 0
_draws = 0


def _size():
    try:
        sz = os.get_terminal_size(sys.stdout.fileno())
        return sz.lines, sz.columns
    except OSError:
        return (-1, -1)


def _log(tag, extra=""):
    global _seq
    _seq += 1
    rows, cols = _size()
    with open(LOG, "a") as fh:
        fh.write("%d %s rows=%d cols=%d %s t=%.3f\n" % (_seq, tag, rows, cols, extra, time.time()))


def _draw():
    """Redraw a bottom-anchored prompt box using ABSOLUTE positioning.

    Absolute positioning cannot itself drift, so if the visible prompt still
    climbs it is Neovim's display of the grid, not our rendering.
    """
    global _draws
    _draws += 1
    rows, cols = _size()
    if rows < 6:
        return
    bar = "-" * max(1, cols - 1)
    out = []
    out.append("\x1b[2J\x1b[H")  # clear + cursor home
    out.append("synthetic claude-ish TUI  draw#%d  size=%dx%d\r\n" % (_draws, rows, cols))
    out.append("(scrollback content)\r\n")
    out.append("\x1b[%d;1H%s" % (rows - 3, bar))   # top rule of input box
    out.append("\x1b[%d;1H> " % (rows - 2))          # prompt line
    out.append("\x1b[%d;1H%s" % (rows - 1, bar))     # bottom rule
    out.append("\x1b[%d;3H" % (rows - 2))            # park cursor right after "> "
    sys.stdout.write("".join(out))
    sys.stdout.flush()


def _on_winch(signum, frame):
    _log("SIGWINCH")
    _draw()


def main():
    open(LOG, "w").close()
    signal.signal(signal.SIGWINCH, _on_winch)

    fd = sys.stdin.fileno()
    old = None
    try:
        old = termios.tcgetattr(fd)
        tty.setraw(fd)
    except (termios.error, OSError):
        pass

    # Mimic a modern TUI: focus reporting + bracketed paste + hide/show cursor.
    sys.stdout.write("\x1b[?1004h\x1b[?2004h")
    sys.stdout.flush()

    _log("START")
    _draw()

    try:
        while True:
            r, _, _ = select.select([fd], [], [], 0.3)
            if fd in r:
                data = os.read(fd, 1024)
                if not data:
                    break
                hexs = data.hex()
                printable = "".join(chr(b) if 32 <= b < 127 else "." for b in data)
                _log("INPUT", "hex=%s repr=%r ascii=%s" % (hexs, data, printable))
                # Focus-in (ESC [ I) -> a modern TUI would re-render here.
                if b"\x1b[I" in data:
                    _log("FOCUS_IN -> redraw")
                    _draw()
                if b"\x1b[O" in data:
                    _log("FOCUS_OUT")
                if data in (b"\x03", b"\x04", b"q"):
                    break
    finally:
        sys.stdout.write("\x1b[?1004l\x1b[?2004l")
        sys.stdout.flush()
        if old is not None:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()

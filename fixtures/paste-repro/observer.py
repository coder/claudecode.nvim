#!/usr/bin/env python3
"""Raw-mode bracketed-paste observer.

Enables DECSET 2004 (bracketed paste), reads raw bytes, logs every read() with
counts of paste START (ESC[200~) / END (ESC[201~) markers, and dumps every raw
byte to <log>.raw for exact content reconstruction. Reveals whether one logical
paste arrives as ONE bracketed-paste segment or is fragmented into many.

Log path: argv[1] or $PASTE_LOG or <tmpdir>/claudecode-paste-observer.log
Quit: raw byte 0x03 (Ctrl-C) or sentinel '<<QUIT>>'.
"""
import sys, os, tty, termios, time, tempfile

LOG = (
    (sys.argv[1] if len(sys.argv) > 1 else None)
    or os.environ.get("PASTE_LOG")
    or os.path.join(tempfile.gettempdir(), "claudecode-paste-observer.log")
)
RAW = LOG + ".raw"
START = b"\x1b[200~"
END = b"\x1b[201~"
SENTINEL = b"<<QUIT>>"

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
log = open(LOG, "w", buffering=1)
raw = open(RAW, "wb", buffering=0)

os.write(1, b"\x1b[?2004h")
os.write(1, b"OBSERVER READY (bracketed paste on). Paste now.\r\n")
log.write("READY\n")

tty.setraw(fd)
allbytes = bytearray()
reads = 0
try:
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        reads += 1
        raw.write(chunk)
        n_start = chunk.count(START)
        n_end = chunk.count(END)
        log.write(
            "READ #%d ts=%.4f bytes=%d start=%d end=%d firstbytes=%r\n"
            % (reads, time.time(), len(chunk), n_start, n_end, bytes(chunk[:24]))
        )
        allbytes += chunk
        if b"\x03" in chunk or SENTINEL in allbytes:
            break
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    os.write(1, b"\x1b[?2004l")
    log.write(
        "TOTAL reads=%d total_bytes=%d start_markers=%d end_markers=%d\n"
        % (reads, len(allbytes), allbytes.count(START), allbytes.count(END))
    )
    log.close(); raw.close()

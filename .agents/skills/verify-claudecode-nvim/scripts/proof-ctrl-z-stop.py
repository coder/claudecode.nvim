#!/usr/bin/env python3
"""Proves that Ctrl-Z in the Claude terminal stops Neovim, as a shell sees it, and never reaches the Claude job (#194).

Usage: proof-ctrl-z-stop.py --provider native|snacks --repo DIR --nvim PATH --node PATH --out NEWDIR [--snacks DIR]

It runs `bash -i` in a pty, starts nvim as a foreground job of that shell, and answers the terminal queries nvim sends.
Neovim 0.12 answers `:suspend` by sending itself SIGSTOP, but only after the terminal replies to the Primary Device
Attributes query (ESC [ c). agent-tty sends no reply, so nvim never stops in a vcn.sh run. This pty replies
ESC [ ? 62 ; c. The Claude job is scripts/ctrl-z-probe-job.mjs, a raw-mode stand-in for the Claude CLI.
Prints `ok <check>` or `FAIL <check>` per check and ends with `CHECKS <n> FAILED <k>`. Exits 1 when a check fails.
Evidence lands in OUT: the job log, the process states, the shell's transcript and the raw pty output.
It signals only the processes it started: the shell, nvim, the nvim server and the job.
"""
import argparse
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

DA1_QUERY = re.compile(rb"\x1b\[0?c")
DA1_REPLY = b"\x1b[?62;c"
ANSI = re.compile(rb"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b[()][A-Z0-9]|\x1b[=>]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1bP.*?\x1b\\", re.S)
CTRL_Z = b"\x1a"
CTRL_BACKSLASH_N = b"\x1c\x0e"  # Ctrl-\ Ctrl-N: leave terminal mode
CTRL_W_H = b"\x17h"
DEADLINE_SECS = 150


class Proof:
    def __init__(self, args):
        self.args = args
        self.out = os.path.abspath(args.out)
        os.makedirs(self.out, mode=0o700)
        self.work = os.path.join(self.out, "work")
        self.home = os.path.join(self.out, "home")
        for sub in (self.work, self.home, os.path.join(self.out, "claude")):
            os.makedirs(sub, mode=0o700)
        with open(os.path.join(self.work, "hello.txt"), "w") as handle:
            handle.write("alpha\nbeta\ngamma\n")
        self.log = os.path.join(self.out, f"ctrl-z-{args.provider}-pty-job.log")
        self.sock = os.path.join(self.out, "nvim.sock")
        self.raw = b""
        self.scan_from = 0
        self.fd = None
        self.shell_pid = None
        self.pids = {}
        self.total = 0
        self.failed = 0

    def child_env(self):
        setup = json.dumps(
            {
                "terminal": {"provider": self.args.provider},
                "terminal_cmd": f"{self.args.node} {os.path.dirname(os.path.abspath(__file__))}/ctrl-z-probe-job.mjs {self.log}",
            }
        )
        return {
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": "C.UTF-8",
            "PATH": "/usr/bin:/bin",
            "HOME": self.home,
            "XDG_CONFIG_HOME": f"{self.home}/c",
            "XDG_DATA_HOME": f"{self.home}/d",
            "XDG_STATE_HOME": f"{self.home}/s",
            "XDG_CACHE_HOME": f"{self.home}/k",
            "CLAUDE_CONFIG_DIR": os.path.join(self.out, "claude"),
            "VCN_REPO": self.args.repo,
            "VCN_SETUP": setup,
            "PS1": "$ ",
        }

    def start_shell(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.work)
            os.execve("/usr/bin/bash", ["bash", "--noprofile", "--norc", "-i"], self.child_env())
        self.shell_pid, self.fd = pid, fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
        self.pids["shell"] = pid

    def pump(self, secs):
        end = time.time() + secs
        while True:
            left = end - time.time()
            if left <= 0:
                break
            ready, _, _ = select.select([self.fd], [], [], min(left, 0.1))
            if not ready:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                break
            if not data:
                break
            self.raw += data
            for match in DA1_QUERY.finditer(self.raw, self.scan_from):
                os.write(self.fd, DA1_REPLY)
                self.scan_from = match.end()

    def wait_for(self, predicate, secs):
        end = time.time() + secs
        while time.time() < end:
            if predicate():
                return True
            self.pump(0.1)
        return bool(predicate())

    def send(self, data):
        os.write(self.fd, data)
        self.pump(0.3)

    def rpc(self, expr):
        env = {"PATH": "/usr/bin:/bin", "HOME": self.home, "XDG_STATE_HOME": f"{self.home}/s"}
        try:
            result = subprocess.run(
                [self.args.nvim, "--server", self.sock, "--remote-expr", expr],
                capture_output=True,
                text=True,
                timeout=5,
                env=env,
            )
        except subprocess.TimeoutExpired:
            return None
        return result.stdout.strip() if result.returncode == 0 else None

    @staticmethod
    def state(pid):
        result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
        return result.stdout.strip()[:1] or "-"

    def job_log(self):
        try:
            with open(self.log) as handle:
                return handle.read()
        except FileNotFoundError:
            return ""

    def job_read(self, hex_byte):
        return re.search(rf"^bytes( [0-9a-f]{{2}})* {hex_byte}( |$)", self.job_log(), re.M) is not None

    def check(self, label, ok):
        self.total += 1
        if not ok:
            self.failed += 1
        print(("ok   " if ok else "FAIL ") + label, flush=True)

    def transcript(self):
        text = ANSI.sub(b"", self.raw).decode("utf-8", "replace").replace("\r", "")
        return re.sub(r"\n{2,}", "\n", text)

    def nvim_tui_pid(self):
        result = subprocess.run(
            ["ps", "-o", "pid=,comm=", "--ppid", str(self.shell_pid)], capture_output=True, text=True
        )
        for line in result.stdout.splitlines():
            pid, _, comm = line.strip().partition(" ")
            if comm.strip() == "nvim":
                return int(pid)
        return None

    def run(self):
        args = self.args
        self.start_shell()
        self.pump(1.0)
        extra = f"--cmd 'set rtp+={args.snacks}' " if args.provider == "snacks" else ""
        init = os.path.join(os.path.dirname(os.path.abspath(__file__)), "init.lua")
        self.send(f"{args.nvim} --listen {self.sock} -u {init} -n {extra}hello.txt\r".encode())
        if not self.wait_for(lambda: self.rpc("mode()") == "n", 20):
            raise RuntimeError("nvim did not answer RPC within 20 s: see the raw pty output")
        self.pids["nvim tui"] = self.nvim_tui_pid()
        self.pids["nvim server"] = int(self.rpc("getpid()"))
        tui = self.pids["nvim tui"]

        self.send(b":ClaudeCode\r")
        if not self.wait_for(lambda: self.rpc("mode()") == "t" and "ready pid=" in self.job_log(), 10):
            raise RuntimeError("the Claude terminal did not open in terminal mode")
        job = int(re.search(r"ready pid=(\d+)", self.job_log()).group(1))
        self.pids["job"] = job
        states = [f"before Ctrl-Z: nvim tui pid {tui} state {self.state(tui)}, job pid {job} state {self.state(job)}"]

        mark = len(self.raw)
        self.send(CTRL_Z)
        stopped = self.wait_for(lambda: self.state(tui) == "T", 6)
        self.pump(1.0)
        states.append(f"after Ctrl-Z in the terminal: nvim state {self.state(tui)}, job state {self.state(job)}")
        shell_saw = b"Stopped" in ANSI.sub(b"", self.raw[mark:])
        self.check("Ctrl-Z in the Claude terminal stopped Neovim (state T)", stopped)
        self.check("the shell reported the stopped job", shell_saw)
        self.check("the job never read the Ctrl-Z byte (0x1a)", not self.job_read("1a"))
        self.check("the job is not stopped", self.state(job) != "T")

        resumed = False
        if stopped:
            self.send(b"fg\r")
            resumed = self.wait_for(lambda: self.state(tui) != "T" and self.rpc("mode()") == "t", 8)
        states.append(f"after fg: nvim state {self.state(tui)}, mode {self.rpc('mode()')}")
        self.check("fg resumed Neovim in terminal mode", resumed)
        self.send(b"x")
        self.check("a typed key (0x78) reaches the job after fg", self.wait_for(lambda: self.job_read("78"), 5))

        self.send(CTRL_BACKSLASH_N)
        self.wait_for(lambda: self.rpc("mode()") == "n", 5)
        self.send(CTRL_W_H)
        in_hello = self.wait_for(lambda: self.rpc("bufname()") == "hello.txt", 5)
        self.send(CTRL_Z)
        control_stopped = in_hello and self.wait_for(lambda: self.state(tui) == "T", 6)
        states.append(f"after Ctrl-Z in the hello.txt window: nvim state {self.state(tui)}")
        self.check("control: Ctrl-Z in a normal window stops Neovim the same way (state T)", control_stopped)
        control_resumed = False
        if control_stopped:
            self.send(b"fg\r")
            control_resumed = self.wait_for(lambda: self.state(tui) != "T" and self.rpc("mode()") == "n", 8)
        self.check("control: fg resumes it", control_resumed)

        with open(os.path.join(self.out, f"ctrl-z-{args.provider}-pty-states.txt"), "w") as handle:
            handle.write("\n".join(states) + "\n")
        print("\n".join(states), file=sys.stderr)

    def finish(self):
        for name, pid in self.pids.items():
            if pid is not None and self.state(pid) != "-":
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        if self.shell_pid is not None:
            try:
                os.waitpid(self.shell_pid, 0)
            except ChildProcessError:
                pass
        if self.fd is not None:
            os.close(self.fd)
        with open(os.path.join(self.out, f"ctrl-z-{self.args.provider}-pty.raw"), "wb") as handle:
            handle.write(self.raw)
        with open(os.path.join(self.out, f"ctrl-z-{self.args.provider}-pty-transcript.txt"), "w") as handle:
            handle.write(self.transcript())


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--provider", choices=("native", "snacks"), required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--nvim", required=True)
    parser.add_argument("--node", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--snacks")
    args = parser.parse_args()
    if args.provider == "snacks" and not (args.snacks and os.path.isfile(os.path.join(args.snacks, "lua/snacks/init.lua"))):
        parser.error("--snacks must be a snacks.nvim checkout")
    proof = Proof(args)
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(RuntimeError(f"no result within {DEADLINE_SECS} s")))
    signal.alarm(DEADLINE_SECS)
    try:
        proof.run()
    except RuntimeError as error:
        proof.check(str(error), False)
    finally:
        signal.alarm(0)
        proof.finish()
    print(f"CHECKS {proof.total} FAILED {proof.failed}")
    return 1 if proof.failed else 0


if __name__ == "__main__":
    sys.exit(main())

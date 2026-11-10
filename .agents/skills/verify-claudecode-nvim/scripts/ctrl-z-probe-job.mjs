#!/usr/bin/env node
// Stand-in for the Claude CLI in a Ctrl-Z check. Like Claude Code, it puts its terminal in raw mode, so the
// terminal does not turn Ctrl-Z (0x1a) into SIGTSTP for it. It logs every byte it reads, and on 0x1a it stops
// itself, the way Claude Code suspends itself ("Claude Code has been suspended"). It sends SIGSTOP, not
// SIGTSTP: the job leads its own session, so its process group is orphaned, and the kernel drops a default-action
// SIGTSTP there. SIGSTOP always stops it, and no shell in the Neovim terminal can `fg` it back.
// Usage: ctrl-z-probe-job.mjs <log-file>. It never starts the real `claude` CLI and needs no network.
import { appendFileSync } from "node:fs";

const log = process.argv[2];
if (!log) {
  console.error("usage: ctrl-z-probe-job.mjs <log-file>");
  process.exit(2);
}
const note = (line) => appendFileSync(log, `${line}\n`);

process.stdin.setRawMode(true);
process.stdin.resume();
console.log("ctrl-z probe job: press keys; Ctrl-Z stops this job");
note(`ready pid=${process.pid}`);

process.stdin.on("data", (chunk) => {
  note(
    `bytes ${[...chunk].map((byte) => byte.toString(16).padStart(2, "0")).join(" ")}`,
  );
  if (chunk.includes(0x1a)) {
    note("ctrl-z reached the job; the job stops itself");
    process.kill(process.pid, "SIGSTOP");
  }
});
process.on("SIGCONT", () => note("job continued"));

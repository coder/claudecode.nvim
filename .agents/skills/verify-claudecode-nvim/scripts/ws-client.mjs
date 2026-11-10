// Plays the Claude Code CLI: connects to the plugin with the lock file's token, sends each line
// appended to OUT_FILE, and appends each message it receives to IN_FILE.
// Usage: node ws-client.mjs <lock file> <out file> <in file>
// The token is read from the 0600 lock file so it never appears in argv.
import {
  appendFileSync,
  openSync,
  readFileSync,
  readSync,
  statSync,
} from "node:fs";

const [lockPath, outPath, inPath] = process.argv.slice(2);
if (!lockPath || !outPath || !inPath) {
  console.error("usage: ws-client.mjs <lock file> <out file> <in file>");
  process.exit(2);
}
const port = lockPath.match(/(\d+)\.lock$/)?.[1];
const { authToken } = JSON.parse(readFileSync(lockPath, "utf8"));
if (!port || !authToken) {
  console.error(`ws-client: no port or authToken in ${lockPath}`);
  process.exit(2);
}

const ws = new WebSocket(`ws://127.0.0.1:${port}`, {
  headers: { "x-claude-code-ide-authorization": authToken },
});
const fd = openSync(outPath, "r");
let offset = 0;
let pending = "";

function pump() {
  const size = statSync(outPath).size;
  if (size <= offset) return;
  const buf = Buffer.alloc(size - offset);
  offset += readSync(fd, buf, 0, buf.length, offset);
  pending += buf.toString("utf8");
  const lines = pending.split("\n");
  pending = lines.pop();
  for (const line of lines) if (line.trim()) ws.send(line);
}

ws.onopen = () => setInterval(pump, 50);
ws.onmessage = (event) => appendFileSync(inPath, `${event.data}\n`);
ws.onerror = (event) =>
  console.error(`ws-client: ${event.message ?? "socket error"}`);
ws.onclose = (event) => {
  console.error(`ws-client: closed (code ${event.code})`);
  process.exit(event.code === 1000 ? 0 : 1);
};

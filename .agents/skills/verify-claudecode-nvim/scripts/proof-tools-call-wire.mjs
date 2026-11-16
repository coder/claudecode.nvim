#!/usr/bin/env node
// Sends malformed and valid `tools/call` messages to the plugin server of one tree over a real WebSocket and judges
// every answer against the case table below. Prints one line per case and ends with one COUNT line.
// Usage: node proof-tools-call-wire.mjs <lock file> <tree> <cwd> <run>   (the launcher starts nvim, then this)
// Exit: 0 every case passed, 1 a case failed or a frame leaked, 2 the probe could not run, or judged fewer cases than
// the table holds (no case at all included), or a path that the leak rule looks for holds a double quote, a backslash
// or a control character.
// The token is read from the 0600 lock file and goes only into the upgrade header, as in ws-client.mjs. The checker
// prints only text that it wrote itself (`stop`) and text of a frame that passed `show`, which withholds a text that
// holds 8 or more characters of the token in a row. It never prints the message or the stack of an exception that Node
// or a library raised, because such a message can quote its input: `die` prints only the class name.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { isDeepStrictEqual } from "node:util";

const stop = (message) => {
  console.error(`proof-tools-call-wire: ${message}`);
  process.exit(2);
};
const die = (error) =>
  stop(`stopped by an unexpected ${error?.constructor?.name}`);
process.on("uncaughtException", die);

const [lockPath, tree, cwd, run] = process.argv.slice(2); // cwd: nvim's, which getWorkspaceFolders reports
if (!run)
  stop("usage: proof-tools-call-wire.mjs <lock file> <tree> <cwd> <run>");

// Normalization. The path rewrite below applies to a text on its own. The cwd goes first, so a work folder under the
// real home folder is not a leak: getWorkspaceFolders names the cwd on purpose. Two readers use it. The leak rule
// reads the text of each frame as the wire sent it (see ws.onmessage). The comparison with the table reads a rebuilt
// copy of the answer (`normalize`), which decodes a text item that holds JSON and rewrites strings but not keys, so
// two keys that the rewrite would make equal never pass as a correct answer.
const PLACEHOLDERS = [
  [cwd, "$CWD"],
  [run, "$RUN"], // the run dir: HOME, XDG dirs, TMPDIR, CLAUDE_CONFIG_DIR, lock file. cwd is beside it, not in it
  [tree, "$TREE"],
  [homedir(), "$HOME"], // the checker has an empty environment, so this is the home of the password database
].filter(([path]) => path.length > 1);
const PATHS = {
  $CWD: "the work folder",
  $RUN: "the temp dir",
  $TREE: "the tree",
  $HOME: "the home folder",
};
// A leak is a Lua position (`.lua:` and a digit), or a path under the run dir, the plugin tree or the real home folder.
// The last three are the placeholders that the normalization leaves in a frame. A frame that holds the auth token is
// one too.
const LEAK = /\.lua:\d|\$RUN|\$TREE|\$HOME/;

// The case table. A row is [name, params of tools/call, expected answer]. An expected answer is one of:
//   refuses(p)  error -32602 whose data names the parameter p
//   ans(v)      a normal answer: result.content is one text item, and v is that text (decoded when it is JSON)
//   fails(...)  an error answer that is not a refusal
// An answer is compared after the normalization, so getWorkspaceFolders is written with $CWD.
const refuses = (param) => {
  if (typeof param !== "string") stop("refuses() needs a parameter name");
  return { param };
};
const ans = (result) => ({ answer: { result } });
const fails = (code, message, data) => ({
  answer: { error: { code, message, data } },
});

// Values of the wrong type for `name` and a string parameter. Without the two objects, and with a string, they are
// the wrong type for `params` and `arguments` too.
const WRONG = Object.entries({
  null: null,
  true: true,
  false: false,
  number: 5,
  emptylist: [],
  list: [1],
  emptyobj: {},
  object: { a: 1 },
});
const NOT_OBJECT = [...WRONG.slice(0, 6), ["string", "x"]];

// A tool has `ok`, its answer to a call without parameters, or string parameters that are required, each with the
// answer to "" (`empty`).
const TOOLS = [
  {
    name: "getWorkspaceFolders",
    ok: {
      folders: [{ name: "work", path: "$CWD", uri: "file://$CWD" }],
      rootPath: "$CWD",
      success: true,
    },
  },
  {
    name: "openFile",
    strings: {
      filePath: {
        empty: fails(-32000, "File operation error", "File not found: "),
      },
    },
  },
];

const rows = [];
const add = (name, params, expect) => rows.push({ name, params, expect });
add("params_absent", undefined, refuses("params"));
for (const [label, value] of NOT_OBJECT)
  add(`params_${label}`, value, refuses("params"));
add("params_emptyobj", {}, refuses("name"));
for (const [label, name] of WRONG)
  add(`name_${label}`, { name }, refuses("name"));
for (const { name, ok, strings = {} } of TOOLS) {
  const bare = ok === undefined ? refuses(Object.keys(strings)[0]) : ans(ok);
  add(`args_${name}_absent`, { name }, bare);
  add(`args_${name}_emptyobj`, { name, arguments: {} }, bare);
  for (const [label, value] of NOT_OBJECT) {
    add(
      `args_${name}_${label}`,
      { name, arguments: value },
      refuses("arguments"),
    );
  }
  for (const [key, { empty }] of Object.entries(strings)) {
    for (const [label, value] of WRONG) {
      add(
        `param_${name}_${key}_${label}`,
        { name, arguments: { [key]: value } },
        refuses(key),
      );
    }
    add(
      `param_${name}_${key}_emptystring`,
      { name, arguments: { [key]: "" } },
      empty,
    );
  }
}

const rewrite = (text) =>
  PLACEHOLDERS.reduce((out, [path, mark]) => out.replaceAll(path, mark), text);
const parse = (text) => {
  try {
    return /^[[{]/.test(text) ? JSON.parse(text) : text;
  } catch {
    return text; // not JSON: plain text. The parser's message is never used.
  }
};
const normalize = (value) => {
  if (typeof value === "string") {
    const decoded = parse(value);
    return decoded === value ? rewrite(value) : normalize(decoded);
  }
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [key, normalize(item)]),
    );
  }
  return value;
};
// An answer as the table states it: the error, or the result with its one text item.
const view = ({ error, result }) => {
  const [item] = result?.content?.length === 1 ? result.content : [];
  return error
    ? { error }
    : { result: item?.type === "text" ? item.text : result };
};

async function main() {
  if (typeof WebSocket !== "function")
    stop("this Node has no global WebSocket: use Node 22 or newer");
  if (rows.length === 0) stop("the case table is empty");
  // The leak rule reads the raw text of a frame, where JSON writes some characters escaped. A path with one of them
  // would not be found in a frame, so the probe refuses to run with it.
  for (const [path, mark] of PLACEHOLDERS) {
    if (/["\\\x00-\x1f\x7f]/.test(path)) {
      stop(
        `the path of ${PATHS[mark]} holds a double quote, a backslash or a control character: use another path`,
      );
    }
  }
  const { authToken } = parse(readFileSync(lockPath, "utf8"));
  if (typeof authToken !== "string" || !authToken)
    stop("the lock file does not parse or has no token");
  const runs = Array.from(
    { length: Math.max(authToken.length - 7, 1) },
    (_, i) => authToken.slice(i, i + 8),
  );
  const holdsToken = (text) => runs.some((run) => text.includes(run));
  const show = (text) => (holdsToken(text) ? "<holds the auth token>" : text);
  const ws = new WebSocket(
    `ws://127.0.0.1:${lockPath.match(/(\d+)\.lock$/)[1]}`,
    {
      headers: { "x-claude-code-ide-authorization": authToken },
    },
  );
  let want = 100; // the id of the call in flight
  let answer = null; // its answer
  let leak = null; // the first frame since the call that leaks, which is any frame, not only the answer
  let leaks = 0;
  let wake = () => {};
  ws.onmessage = ({ data }) => {
    // The leak rule and the token rule read the text of the frame as the wire sent it. An escaped slash, a run of
    // backslashes and a slash at any depth of nesting, is read as a slash. Then the path rewrite applies. No parse and
    // no rebuild comes before them.
    const text = rewrite(String(data).replace(/\\+\//g, "/"));
    if (holdsToken(text) || LEAK.test(text)) {
      leaks++;
      leak ??= text;
    }
    const frame = parse(String(data));
    if (typeof frame !== "object") {
      return stop("the server sent a frame that is not JSON");
    }
    if (frame?.id === want) {
      answer ??= normalize(frame);
      wake();
    }
  };
  ws.onclose = () => stop("the server closed the connection");
  await new Promise((resolve) => {
    ws.onopen = () => {
      ws.onerror = null; // after the handshake, onclose reports a lost connection
      resolve();
    };
    ws.onerror = () => stop("WebSocket handshake failed");
  });

  let judged = 0;
  let failed = 0;
  for (const { name, params, expect } of rows) {
    answer = leak = null;
    const replied = new Promise((resolve) => (wake = resolve));
    ws.send(
      JSON.stringify({
        jsonrpc: "2.0",
        id: ++want,
        method: "tools/call",
        params,
      }),
    );
    await Promise.race([
      replied,
      new Promise((resolve) => setTimeout(resolve, 3000)),
    ]);
    const seen = answer && view(answer);
    const text = JSON.stringify(seen);
    let problem = null;
    if (leak) problem = `a frame leaks a path: ${leak}`;
    else if (!answer) problem = "no answer in 3 s";
    else if (expect.param !== undefined) {
      if (
        seen.error?.code !== -32602 ||
        !new RegExp(`\\b${expect.param}\\b`).test(String(seen.error.data))
      ) {
        problem = `want -32602 naming ${expect.param}, got ${text}`;
      }
    } else if (
      !isDeepStrictEqual(seen, JSON.parse(JSON.stringify(expect.answer)))
    ) {
      problem = `want ${JSON.stringify(expect.answer)}, got ${text}`;
    }
    judged++;
    if (problem) failed++;
    console.log(
      problem ? `FAIL: ${name}: ${show(problem).slice(0, 240)}` : `ok: ${name}`,
    );
  }
  // A frame that comes within 200 ms after the last answer is read too, and counted once.
  leak = null;
  await new Promise((resolve) => setTimeout(resolve, 200));
  if (leak) {
    failed++;
    console.log(
      `FAIL: after the last case: ${show(`a frame leaks a path: ${leak}`).slice(0, 240)}`,
    );
  }
  if (judged !== rows.length)
    stop(`the checker judged ${judged} of ${rows.length} cases`);
  console.log(
    `COUNT tools-call-wire cases=${judged} failed=${failed} leaks=${leaks}`,
  );
  process.exit(failed || leaks ? 1 : 0);
}
main().catch(die);

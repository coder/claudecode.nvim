#!/usr/bin/env node
// Sends malformed and valid `tools/call` messages to the plugin server of one tree over a real WebSocket and judges
// every answer against the case table below. Prints one line per case and ends with one COUNT line.
// Usage: node proof-tools-call-wire.mjs <lock file> <tree> <cwd>   (proof-tools-call-wire.sh starts nvim, then this)
// Exit: 0 every case passed, 1 a case failed or an answer leaked, 2 the probe could not run.
// The token is read from the 0600 lock file and goes only into the upgrade header, as in ws-client.mjs.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { isDeepStrictEqual } from "node:util";

const [lockPath, tree, cwd] = process.argv.slice(2); // cwd: nvim's, the workspace folder getWorkspaceFolders reports
if (!cwd) {
  console.error("usage: proof-tools-call-wire.mjs <lock file> <tree> <cwd>");
  process.exit(2);
}

// Normalization. Every string of a decoded answer is rewritten before it is compared or checked for a leak. The cwd
// goes first, so a run dir under the real home folder is not a leak: getWorkspaceFolders names the cwd on purpose.
const PLACEHOLDERS = [
  [cwd, "$CWD"],
  [tree, "$TREE"],
  [homedir(), "$HOME"],
].filter(([path]) => path.length > 1);
// A leak is a Lua source path with a line number, the plugin tree, or a path under the real home folder. The last
// two are the placeholders that the normalization leaves in an answer.
const LEAK = /\.lua:\d|\$TREE|\$HOME/;

// The case table. A row is [name, params of tools/call, expected answer]. An expected answer is one of:
//   refuses(p)  error -32602 whose data names the parameter p
//   ans(v)      a normal answer: result.content is one text item, and v is that text (decoded when it is JSON)
//   fails(...)  an error answer that is not a refusal
// An answer is compared after the normalization, so getWorkspaceFolders is written with $CWD.
const refuses = (param) => {
  assert(typeof param === "string", "refuses() needs a parameter name");
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

const normalize = (value) => {
  if (typeof value === "string") {
    return PLACEHOLDERS.reduce(
      (text, [path, mark]) => text.replaceAll(path, mark),
      value,
    );
  }
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [key, normalize(item)]),
    );
  }
  return value;
};
// An answer as the table states it: the error, or the result with its one text item decoded.
const view = ({ error, result }) => {
  if (error) return { error };
  const [item] = result?.content?.length === 1 ? result.content : [];
  if (item?.type !== "text") return { result };
  try {
    return {
      result: /^[[{]/.test(item.text) ? JSON.parse(item.text) : item.text,
    };
  } catch {
    return { result: item.text };
  }
};

const die = (error) => {
  console.error(`proof-tools-call-wire: ${error.message}`);
  process.exit(2);
};
process.on("uncaughtException", die);

async function main() {
  if (typeof WebSocket !== "function")
    throw new Error("this Node has no global WebSocket: use Node 22 or newer");
  const { authToken } = JSON.parse(readFileSync(lockPath, "utf8"));
  const ws = new WebSocket(
    `ws://127.0.0.1:${lockPath.match(/(\d+)\.lock$/)[1]}`,
    {
      headers: { "x-claude-code-ide-authorization": authToken },
    },
  );
  let want = 100; // the id of the call in flight
  let answer = null; // its answer
  let wake = () => {};
  ws.onmessage = ({ data }) => {
    const frame = JSON.parse(data);
    if (frame.id === want) {
      answer ??= frame;
      wake();
    }
  };
  ws.onclose = () => die(new Error("the server closed the connection"));
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = () => reject(new Error("WebSocket handshake failed"));
  });

  let failed = 0;
  let leaks = 0;
  for (const { name, params, expect } of rows) {
    answer = null;
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
    const seen = answer && normalize(view(answer));
    const text = JSON.stringify(seen);
    const leaked = LEAK.test(text);
    let problem = null;
    if (!answer) problem = "no answer in 3 s";
    else if (leaked) problem = `the answer leaks a path: ${text}`;
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
    if (leaked) leaks++;
    if (problem) failed++;
    console.log(
      problem ? `FAIL: ${name}: ${problem.slice(0, 240)}` : `ok: ${name}`,
    );
  }
  console.log(
    `COUNT tools-call-wire cases=${rows.length} failed=${failed} leaks=${leaks}`,
  );
  process.exit(failed ? 1 : 0);
}
main().catch(die);

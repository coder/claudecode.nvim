#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const { execFile, execFileSync } = require("node:child_process");
const {
  copyFileSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const http = require("node:http");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { promisify } = require("node:util");

const runner = require("./release-please-runner.js");

const execFileAsync = promisify(execFile);

function commit(type, bareMessage) {
  return {
    bareMessage,
    message: `${type}: ${bareMessage}`,
    notes: [],
    references: [],
    scope: null,
    sha: "abc123",
    type,
  };
}

function buildOptions() {
  return {
    currentTag: "v0.4.0",
    owner: "coder",
    previousTag: "v0.3.0",
    repository: "claudecode.nvim",
    version: "0.4.0",
  };
}

function testPrettierResolution() {
  assert.equal(
    runner.resolvePrettierBin({ PRETTIER_BIN: "/tmp/prettier" }),
    "/tmp/prettier",
  );
  assert.equal(
    runner.resolvePrettierBin({}, () => false),
    "prettier",
  );
}

async function testCommuniqueArgs() {
  assert.deepEqual(
    runner.buildCommuniqueArgs({
      repo: "coder/claudecode.nvim",
      outputFile: "/tmp/notes.md",
      previousTag: "v0.3.0",
      model: "test-model",
    }),
    [
      "generate",
      "HEAD",
      "v0.3.0",
      "--concise",
      "--repo",
      "coder/claudecode.nvim",
      "--output",
      "/tmp/notes.md",
      "--model",
      "test-model",
    ],
  );
}

async function testHeadingNormalization() {
  assert.equal(
    runner.normalizeCommuniqueBody("# v0.4.0\n\n## [Features]\n\n- Added x"),
    "### [Features]\n\n- Added x",
  );
  assert.equal(
    runner.normalizeCommuniqueBody(
      "## Features\n\n```md\n## Not a heading\n```",
    ),
    "### Features\n\n```md\n## Not a heading\n```",
  );
}

async function testUnreleasedUpdater() {
  const updated = new runner.UnreleasedAwareChangelog({
    changelogEntry: "## [0.4.0] - 2026-06-15\n\n* Added x",
  }).updateContent(
    "# Changelog\n\n## [Unreleased]\n\n### Features\n\n- Draft\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n",
  );
  assert.equal(
    updated,
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n",
  );
  assert.equal(updated, runner.formatChangelogMarkdown(updated));
}

async function testFenceTracking() {
  // A fence closes only on the same character, at least as long as its opener.
  // A trailing `\r` is part of the line ending, so the CRLF cases still match.
  const outside = (lines) =>
    runner.findLineOutsideFences(
      lines,
      0,
      (line) => line.replace(/\r$/, "") === "## Real",
    );

  assert.equal(
    outside(["````md", "```", "## Real", "````", "## Real"]),
    4,
    "a shorter backtick line must not close a four-backtick fence",
  );
  assert.equal(
    outside(["~~~", "```", "## Real", "~~~", "## Real"]),
    4,
    "backticks must not close a tilde fence",
  );
  assert.equal(
    outside(["```", "~~~", "## Real", "```", "## Real"]),
    4,
    "tildes must not close a backtick fence",
  );
  assert.equal(
    outside(["~~~~", "~~~", "## Real", "~~~~~", "## Real"]),
    4,
    "a shorter tilde line must not close a tilde fence, a longer one closes it",
  );
  assert.equal(
    outside(["```", "```js", "## Real", "```", "## Real"]),
    4,
    "a closing fence cannot carry an info string",
  );
  assert.equal(
    outside(["```", "## Real", "``` ", "## Real"]),
    3,
    "a closing fence can be followed by a space",
  );
  assert.equal(
    outside(["```", "## Real", "```\t", "## Real"]),
    3,
    "a closing fence can be followed by a tab",
  );
  assert.equal(
    outside(["```", "## Real", "```  \t ", "## Real"]),
    3,
    "a closing fence can be followed by any run of spaces and tabs",
  );
  assert.equal(
    outside(["```", "## Real", "```\f", "## Real", "```", "## Real"]),
    5,
    "only spaces and tabs can follow a closing fence",
  );
  assert.equal(
    outside(["~~~", "## Real", "~~~ ", "## Real"]),
    3,
    "a closing tilde fence can be followed by a space",
  );
  assert.equal(
    outside(["~~~", "## Real", "~~~\t", "## Real"]),
    3,
    "a closing tilde fence can be followed by a tab",
  );
  assert.equal(
    outside(["```", "## Real", "````", "## Real"]),
    3,
    "a longer fence closes a shorter one",
  );
  assert.equal(
    outside(["```\r", "## Real\r", "```\r", "## Real"]),
    3,
    "a CRLF line ending does not stop a backtick fence from opening or closing",
  );
  assert.equal(
    outside(["~~~\r", "## Real\r", "~~~\r", "## Real"]),
    3,
    "a CRLF line ending does not stop a tilde fence from opening or closing",
  );
  assert.equal(
    outside(["```", "## Real", "    ```", "## Real", "```", "## Real"]),
    5,
    "a closing fence indented by four spaces does not close",
  );
  assert.equal(
    outside(["```", "## Real", "\t```", "## Real", "```", "## Real"]),
    5,
    "a closing fence indented by a tab does not close",
  );
  assert.equal(
    outside(["~~~", "## Real", "\t~~~", "## Real", "~~~", "## Real"]),
    5,
    "a closing tilde fence indented by a tab does not close",
  );
  assert.equal(
    outside(["``", "## Real", "``", "## Real"]),
    1,
    "two backticks do not open a fence",
  );
  assert.equal(
    outside(["~~", "## Real", "~~", "## Real"]),
    1,
    "two tildes do not open a fence",
  );
  assert.equal(
    outside(["   ```", "## Real", "   ```", "## Real"]),
    3,
    "a fence may be indented by up to three spaces",
  );
  assert.equal(
    outside(["    ```", "## Real"]),
    1,
    "four spaces of indent make a code line, not a fence",
  );
  assert.equal(
    outside(["\t```", "## Real"]),
    1,
    "a tab of indent makes a code line, not a fence",
  );
  assert.equal(
    outside(["\t~~~", "## Real"]),
    1,
    "a tab of indent makes a code line, not a tilde fence",
  );
  assert.equal(
    outside(["```js```", "## Real"]),
    1,
    "a backtick fence cannot carry a backtick in its info string",
  );
  assert.equal(
    outside(["~~~ a`b", "## Real", "~~~", "## Real"]),
    3,
    "a tilde fence can carry a backtick in its info string",
  );
  assert.equal(
    outside(["```~~~", "## Real", "```", "## Real"]),
    3,
    "a backtick fence can carry tildes in its info string",
  );
  assert.equal(
    outside(["~~~ ~~~", "## Real", "~~~", "## Real"]),
    3,
    "a tilde fence can carry tildes in its info string",
  );
  assert.equal(
    outside(["```", "## Real"]),
    -1,
    "an unclosed fence runs to the end of the text",
  );
  assert.equal(
    outside(["````md", "## Real", "````", "## Real"]),
    3,
    "a four-backtick line opens a fence, and a four-backtick line closes it",
  );
  // The info string of a backtick opener can hold anything but a backtick.
  for (const opener of [
    "``` js title=x",
    "```\tjs",
    "```c++",
    "```{r}",
    "```\fjs",
  ]) {
    assert.equal(
      outside([opener, "## Real", "```", "## Real"]),
      3,
      `a backtick fence can carry the info string in ${JSON.stringify(opener)}`,
    );
  }
  assert.equal(
    outside(["~~~\tjs", "## Real", "~~~", "## Real"]),
    3,
    "a tilde fence can carry a tab in its info string",
  );
  assert.equal(
    outside(["```", "## Real", "```\u00a0", "## Real", "```", "## Real"]),
    5,
    "a no-break space cannot follow a closing fence",
  );
  // A closer's length counts only its marker run: not its indent, not trailing blanks.
  assert.equal(
    outside(["````md", "  ```", "## Real", "````", "## Real"]),
    4,
    "an indented shorter closer does not close a longer fence",
  );
  assert.equal(
    outside(["````md", "``` ", "## Real", "````", "## Real"]),
    4,
    "blanks after a shorter closer do not make it long enough",
  );
  // Any printable character can be in an info string, but no backtick after backticks.
  const printable = Array.from({ length: 0x7e - 0x20 }, (_, k) =>
    String.fromCharCode(0x21 + k),
  ).join("");
  assert.equal(
    outside([
      `\`\`\` ${printable.replace("`", "")} \v\u00a0x`,
      "## Real",
      "```",
      "## Real",
    ]),
    3,
    "a backtick fence can carry any character but a backtick in its info string",
  );
  assert.equal(
    outside([`~~~ ${printable} \f\u00a0x`, "## Real", "~~~", "## Real"]),
    3,
    "a tilde fence can carry any character in its info string",
  );
  assert.equal(
    outside(["```", "``~", "## Real", "```", "## Real"]),
    4,
    "a line of mixed markers does not close a fence",
  );
  assert.equal(
    outside(["\u00a0```", "## Real"]),
    1,
    "a no-break space is not indent for an opener",
  );
  assert.equal(
    outside(["```", "## Real", "\u00a0```", "## Real", "```", "## Real"]),
    5,
    "a no-break space is not indent for a closer",
  );
  assert.equal(
    outside(["```", "## Real", "```\v", "## Real", "```", "## Real"]),
    5,
    "a vertical tab cannot follow a closing fence",
  );
  assert.equal(
    outside(["`````md", "## Real", "`````", "## Real"]),
    3,
    "a five-backtick line opens a fence, and a five-backtick line closes it",
  );
  assert.equal(
    outside(["~~~~~", "~~~~", "## Real", "~~~~~", "## Real"]),
    4,
    "four tildes do not close a five-tilde fence",
  );

  // CommonMark's rule for every marker length that matters: a closer closes the fence if and only if it uses the
  // opener's character, has at least as many markers, and has at most 3 spaces of indent. Blanks around it change
  // nothing, so each row has as many trailing blanks as indent. The lengths run from 3 to 10, then 100 and 101, to
  // catch a cap on a marker run, for example at 4 or at 100.
  const lengths = [3, 4, 5, 6, 7, 8, 9, 10, 100, 101];
  for (const marker of ["`", "~"]) {
    const otherMarker = marker === "`" ? "~" : "`";
    for (const openerLength of lengths) {
      for (const closerLength of lengths) {
        for (const indent of [0, 1, 2, 3, 4]) {
          const blanks = " ".repeat(indent);
          assert.equal(
            outside([
              marker.repeat(openerLength),
              "## Real",
              `${blanks}${marker.repeat(closerLength)}${blanks}`,
              "## Real",
            ]),
            closerLength >= openerLength && indent <= 3 ? 3 : -1,
            `a closer of ${closerLength} with ${indent} spaces of indent against an opener of ${openerLength} ${marker}`,
          );
        }
      }
      assert.equal(
        outside([
          marker.repeat(openerLength),
          "## Real",
          otherMarker.repeat(openerLength + 1),
          "## Real",
        ]),
        -1,
        `${otherMarker} must not close a fence of ${openerLength} ${marker}`,
      );
    }
    // An opener has at most 3 spaces of indent. With 4 it is a code line.
    for (const indent of [0, 1, 2, 3, 4]) {
      assert.equal(
        outside([
          `${" ".repeat(indent)}${marker.repeat(3)}`,
          "## Real",
          marker.repeat(3),
          "## Real",
        ]),
        indent <= 3 ? 3 : 1,
        `an opener of ${marker} with ${indent} spaces of indent`,
      );
    }
  }

  // One character at a time, so a rule that rejects a single character fails with its name. The marker itself is
  // left out: more markers make a longer run. After the markers, an opener takes any other character as info string,
  // and a closer takes only blanks, so any other character keeps the fence open.
  const characters = [];
  for (let code = 0x20; code <= 0x7e; code += 1) {
    characters.push(String.fromCharCode(code));
  }
  characters.push(
    "\v",
    "\f",
    "\u00a0",
    "\u2003",
    "\u3000",
    "\u00e9",
    "\u2028",
    "\u0085",
  );
  for (const marker of ["`", "~"]) {
    const fence = marker.repeat(3);
    for (const character of characters.filter((other) => other !== marker)) {
      const name = JSON.stringify(character);
      assert.equal(
        outside([fence + character, "## Real", fence, "## Real"]),
        3,
        `a fence of ${marker} can carry ${name} in its info string`,
      );
      if (character !== " ") {
        assert.equal(
          outside([
            fence,
            "## Real",
            fence + character,
            "## Real",
            fence,
            "## Real",
          ]),
          5,
          `${name} after a closing fence of ${marker} keeps the fence open`,
        );
      }
    }
  }
  assert.equal(
    outside(["```", "## Real", "``` `", "## Real", "```", "## Real"]),
    5,
    "a backtick after a blank keeps the fence open",
  );

  // `findLineOutsideFences` never returns a fence line, a line inside a fence, or a closer, even
  // when the predicate matches every line.
  const anyLine = () => true;
  assert.equal(
    runner.findLineOutsideFences(["```", "inside", "```", "tail"], 0, anyLine),
    3,
    "an opener, a line inside the fence, and a closer are not outside the fence",
  );
  assert.equal(
    runner.findLineOutsideFences(["~~~", "inside", "~~~"], 0, anyLine),
    -1,
    "a text that is only a tilde fence has no line outside it",
  );
  assert.equal(
    runner.findLineOutsideFences(["```", "inside"], 0, anyLine),
    -1,
    "an unclosed fence leaves no line outside it",
  );
  assert.equal(
    runner.findLineOutsideFences(
      ["outside", "```", "inside", "```", "outside"],
      1,
      anyLine,
    ),
    4,
    "the search starts at `start` and still skips the fence lines",
  );
  assert.equal(
    runner.findLineOutsideFences(["a", "b"], 1, anyLine),
    1,
    "the line at `start` itself can match",
  );
  assert.equal(
    runner.findLineOutsideFences(["```", "## x", "```", "y"], 1, anyLine),
    3,
    "fence tracking starts at line 0, so a fence that opens before `start` still hides its lines",
  );

  // The Communique body keeps headings inside a longer or tilde fence as is.
  assert.equal(
    runner.normalizeCommuniqueBody(
      "## A\n\n````md\n```\n## Not a heading\n````\n\n## B",
    ),
    "### A\n\n````md\n```\n## Not a heading\n````\n\n### B",
  );
  assert.equal(
    runner.normalizeCommuniqueBody(
      "## A\n\n~~~md\n```\n## Not a heading\n~~~\n\n## B",
    ),
    "### A\n\n~~~md\n```\n## Not a heading\n~~~\n\n### B",
  );
  // The body is split on `\n` only, so CRLF lines keep their `\r`.
  for (const marker of ["```", "~~~"]) {
    assert.equal(
      runner.normalizeCommuniqueBody(
        `## A\r\n${marker}\r\n## inside\r\n${marker}\r\n## B`,
      ),
      `### A\r\n${marker}\r\n## inside\r\n${marker}\r\n### B`,
    );
  }
}

async function testUnreleasedUpdaterFences() {
  const entry = "## [0.4.0] - 2026-06-15\n\n* Added x";
  const released =
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n";

  // A four-backtick fence in the draft flipped the fence state for the rest of
  // the file, so the existing release below it was dropped.
  for (const [open, close] of [
    ["````md", "````"],
    ["~~~md", "~~~"],
  ]) {
    const updated = new runner.UnreleasedAwareChangelog({
      changelogEntry: entry,
    }).updateContent(
      `# Changelog\n\n## [Unreleased]\n\n${open}\n\`\`\`\n## Not a heading\n${close}\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n`,
    );
    assert.equal(updated, released);
  }

  // An Unreleased heading inside a fence is not the anchor.
  const updated = new runner.UnreleasedAwareChangelog({
    changelogEntry: entry,
  }).updateContent(
    "# Changelog\n\n````text\n```\n## [Unreleased]\n````\n\n## [Unreleased]\n\n- Draft\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n",
  );
  assert.equal(
    updated,
    "# Changelog\n\n````text\n```\n## [Unreleased]\n````\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n",
  );
}

function testPullRequestOutputs() {
  assert.deepEqual(runner.formatPullRequestOutputs([]), {
    prs_created: "false",
    pr_branches: "",
    pr_metadata: "[]",
  });
  assert.deepEqual(
    runner.formatPullRequestOutputs([
      {
        headBranchName: "release-please--branches--main",
        title: { toString: () => "chore(release): 0.4.0" },
      },
    ]),
    {
      prs_created: "true",
      pr_branches: "release-please--branches--main",
      pr_metadata:
        '[{"branch":"release-please--branches--main","title":"chore(release): 0.4.0"}]',
    },
  );
}

async function testInternalCommitSkipsCommunique() {
  const notes = runner.createCommuniqueChangelogNotes(async () => {
    throw new Error("Communique should not run for internal-only commits");
  });
  const body = await notes.buildNotes(
    [commit("ci", "add release automation")],
    buildOptions(),
  );
  assert.equal(runner.releasePleaseNotesAreEmpty(body), true);
}

async function testReleasableCommitRunsCommunique() {
  let invoked = false;
  const notes = runner.createCommuniqueChangelogNotes(
    async (args) => {
      invoked = true;
      const outputIndex = args.indexOf("--output") + 1;
      assert.notEqual(outputIndex, 0, "Communique args must include --output");
      writeFileSync(
        args[outputIndex],
        "# v0.4.0\n\n## [Features]\n\n- Fixed x\n",
      );
    },
    { ANTHROPIC_API_KEY: "test-key" },
  );
  const body = await notes.buildNotes(
    [commit("fix", "fix terminal focus")],
    buildOptions(),
  );
  assert.equal(invoked, true);
  assert.match(body, /^## \[0\.4\.0\] - \d{4}-\d{2}-\d{2}/);
  assert.ok(body.includes("### [Features]\n\n- Fixed x"), body);
}

const CHARS_PER_TOKEN = 4;

/**
 * Serves the Anthropic Messages API with one fixed submit_release_notes call.
 * Like the real API, it cuts the call off at the request's max_tokens and keeps
 * only the fields that finished before the cut.
 */
function startFakeAnthropic(submission) {
  const requests = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      const request = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      const submitTool = request.tools.find(
        (tool) => tool.name === "submit_release_notes",
      );
      assert.ok(submitTool, "request must offer submit_release_notes");
      let usedTokens = 0;
      let truncated = false;
      const input = {};
      for (const field of submitTool.input_schema.required) {
        const text = submission[field];
        assert.equal(typeof text, "string", `no text for ${field}`);
        const tokens = Math.ceil(text.length / CHARS_PER_TOKEN);
        if (usedTokens + tokens > request.max_tokens) {
          usedTokens = request.max_tokens;
          truncated = true;
          break;
        }
        usedTokens += tokens;
        input[field] = text;
      }
      requests.push({ maxTokens: request.max_tokens, truncated });
      res.writeHead(200, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          id: "msg_test",
          type: "message",
          role: "assistant",
          model: request.model,
          content: [
            {
              type: "tool_use",
              id: "toolu_test",
              name: "submit_release_notes",
              input,
            },
          ],
          stop_reason: truncated ? "max_tokens" : "tool_use",
          usage: { input_tokens: 100, output_tokens: usedTokens },
        }),
      );
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      resolve({
        requests,
        url: `http://127.0.0.1:${server.address().port}`,
        close: () => {
          server.closeAllConnections();
          server.close();
        },
      });
    });
  });
}

// Communique 1.1.3 asks the model for changelog, title, and body in one call.
// For the ~140 PRs since v0.3.0 that call did not fit in the 4096-token
// default: all three attempts stopped at exactly 4096 output tokens. This
// submission is bigger than the default and smaller than communique.toml allows.
async function testCommuniqueConfigFitsReleaseNotes() {
  const changelog = `## Added\n${"- A user-visible change with a PR link.\n".repeat(230)}`;
  const submission = {
    changelog,
    release_title: "A release title",
    release_body: `${"- A longer release body line with detail.\n".repeat(350)}`,
  };
  const submittedTokens = Math.ceil(
    Object.values(submission).join("").length / CHARS_PER_TOKEN,
  );
  assert.ok(
    submittedTokens > 4096 && submittedTokens < 8192,
    `submission must exceed communique's default budget, got ${submittedTokens} tokens`,
  );

  const root = mkdtempSync(join(tmpdir(), "communique-config-"));
  const fake = await startFakeAnthropic(submission);
  try {
    const gitEnv = {
      PATH: process.env.PATH,
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_AUTHOR_NAME: "test",
      GIT_AUTHOR_EMAIL: "test@example.invalid",
      GIT_COMMITTER_NAME: "test",
      GIT_COMMITTER_EMAIL: "test@example.invalid",
    };
    const git = (...args) =>
      execFileSync("git", args, { cwd: root, env: gitEnv, stdio: "pipe" });
    git("init", "-q");
    git("commit", "-q", "--allow-empty", "-m", "chore: first");
    git("tag", "v0.0.1");
    git("commit", "-q", "--allow-empty", "-m", "fix: second (#1)");
    copyFileSync(
      join(__dirname, "..", "communique.toml"),
      join(root, "communique.toml"),
    );

    const outputFile = join(root, "notes.md");
    // The environment lists every variable, so no real API key reaches communique.
    await execFileAsync(
      "communique",
      [
        "generate",
        "HEAD",
        "v0.0.1",
        "--concise",
        "--repo",
        "coder/claudecode.nvim",
        "--base-url",
        fake.url,
        "--output",
        outputFile,
      ],
      {
        cwd: root,
        env: {
          ...gitEnv,
          ANTHROPIC_API_KEY: "test-key-not-real",
          HOME: root,
        },
        timeout: 60_000,
      },
    );

    assert.deepEqual(
      fake.requests.map(({ truncated }) => truncated),
      [false],
      `communique must get its whole submission through on the first try, requests: ${JSON.stringify(fake.requests)}`,
    );
    assert.equal(readFileSync(outputFile, "utf8").trim(), changelog.trim());
  } finally {
    fake.close();
    rmSync(root, { recursive: true, force: true });
  }
}

async function main() {
  testPrettierResolution();
  await testCommuniqueArgs();
  await testHeadingNormalization();
  await testUnreleasedUpdater();
  await testFenceTracking();
  await testUnreleasedUpdaterFences();
  testPullRequestOutputs();
  await testInternalCommitSkipsCommunique();
  await testReleasableCommitRunsCommunique();
  await testCommuniqueConfigFitsReleaseNotes();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

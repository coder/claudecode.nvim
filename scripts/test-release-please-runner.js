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
  testPullRequestOutputs();
  await testInternalCommitSkipsCommunique();
  await testReleasableCommitRunsCommunique();
  await testCommuniqueConfigFitsReleaseNotes();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

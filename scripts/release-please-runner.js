#!/usr/bin/env node
"use strict";

/**
 * Release Please runner with Communique changelog notes.
 *
 * The stock release-please action cannot register a custom changelog generator.
 * This runner uses release-please as a library, registers `communique` as a
 * changelog-notes type, and swaps the stock CHANGELOG updater so the permanent
 * `## [Unreleased]` section stays at the top of CHANGELOG.md.
 */

const assert = require("node:assert/strict");
const { execFile, execFileSync } = require("node:child_process");
const {
  appendFileSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const process = require("node:process");
const { promisify } = require("node:util");

const {
  GitHub,
  Manifest,
  registerChangelogNotes,
  registerReleaseType,
} = require("release-please");
const {
  DefaultChangelogNotes,
} = require("release-please/build/src/changelog-notes/default.js");
const { Simple } = require("release-please/build/src/strategies/simple.js");
const { Changelog } = require("release-please/build/src/updaters/changelog.js");

const LOCAL_PRETTIER_BIN = join(
  __dirname,
  "node_modules",
  ".bin",
  process.platform === "win32" ? "prettier.cmd" : "prettier",
);

const execFileAsync = promisify(execFile);

const UNRELEASED_HEADING_PATTERN = /^#{2,3} \[?Unreleased\]?[ \t]*$/;
// An H1 or H2 heading ends the Unreleased section; H3 stays inside it because
// hand-staged drafts use Keep-a-Changelog `### Added`-style subsections.
const NEXT_SECTION_PATTERN = /^##? /;
const TITLE_PATTERN = /^# .+$/;
// CommonMark ends a line with LF, CR, or CR LF. Every text is split with this
// one rule (see `splitLines`), so a fence pattern never sees a bare CR inside a
// line.
const LINE_ENDING_PATTERN = /\r\n|\r|\n/g;
// CommonMark fences: up to three spaces of indent, then three or more backticks
// or tildes. A backtick opener cannot have a backtick after it. A closer can
// have nothing after it but blanks. A caller that splits on `\n` alone leaves
// the `\r` of a CRLF ending on a line, so the patterns allow one there. `.` does
// not match `\r`, so no pattern here uses it.
const FENCE_OPEN_PATTERN = /^ {0,3}(?:(`{3,})[^`]*|(~{3,})[^\n]*)$/;
const FENCE_CLOSE_PATTERN = /^ {0,3}(`{3,}|~{3,})[ \t\r]*$/;

/**
 * Mirrors release-note workflow credentials: Anthropic works standalone;
 * OpenAI-compatible endpoints additionally need an explicit model selection.
 */
function assertLlmCredentials(env) {
  assert.equal(typeof env, "object", "env must be an object");
  const anthropicKey = env.ANTHROPIC_API_KEY ?? "";
  const openaiKey = env.OPENAI_API_KEY ?? "";
  const model = env.COMMUNIQUE_MODEL ?? "";

  if (anthropicKey === "" && openaiKey === "") {
    throw new Error(
      "ANTHROPIC_API_KEY or OPENAI_API_KEY is required to generate changelog entries with Communique.",
    );
  }
  if (anthropicKey === "" && model === "") {
    throw new Error(
      "Set COMMUNIQUE_MODEL when using OPENAI_API_KEY so Communique can select an OpenAI-compatible model.",
    );
  }
}

/**
 * `communique generate HEAD [PREV_TAG] --concise` emits a changelog-entry body
 * without touching CHANGELOG.md. Passing the previous tag keeps Communique and
 * release-please on the same commit range.
 */
function buildCommuniqueArgs(invocation) {
  assert.equal(typeof invocation, "object", "invocation must be an object");
  assert.equal(typeof invocation.repo, "string", "repo must be a string");
  assert.notEqual(invocation.repo, "", "repo must not be empty");
  assert.equal(
    typeof invocation.outputFile,
    "string",
    "outputFile must be a string",
  );
  assert.notEqual(invocation.outputFile, "", "outputFile must not be empty");

  const args = ["generate", "HEAD"];
  if (invocation.previousTag !== undefined && invocation.previousTag !== "") {
    assert.equal(
      typeof invocation.previousTag,
      "string",
      "previousTag must be a string",
    );
    args.push(invocation.previousTag);
  }
  args.push(
    "--concise",
    "--repo",
    invocation.repo,
    "--output",
    invocation.outputFile,
  );
  if (invocation.model !== undefined && invocation.model !== "") {
    assert.equal(typeof invocation.model, "string", "model must be a string");
    args.push("--model", invocation.model);
  }
  return args;
}

/**
 * Splits `text` into lines by CommonMark's rule: a line ends with LF, CR, or
 * CR LF. `endings[i]` is the ending after `lines[i]`, and the last one is "".
 * Joining each line with its ending gives `text` back.
 */
function splitLines(text) {
  assert.equal(typeof text, "string", "text must be a string");
  const lines = text.split(LINE_ENDING_PATTERN);
  const endings = [...(text.match(LINE_ENDING_PATTERN) ?? []), ""];
  assert.equal(lines.length, endings.length, "each line needs an ending");
  return { lines, endings };
}

/**
 * Matches `pattern` against `line` and keeps no state. A `g` or `y` flag on a
 * shared pattern keeps `lastIndex` after a match, and the next line would then
 * start its match there: a fence would open or close late, or never.
 */
function matchLine(pattern, line) {
  return new RegExp(pattern).exec(line);
}

/**
 * The fence that is open after `line`: the opener's marker (for example
 * "````" or "~~~") or null. A fence closes only on a marker of the same
 * character that is at least as long as the opener's. An unclosed fence runs
 * to the end of the text.
 */
function nextOpenFence(openFence, line) {
  assert.ok(
    openFence === null || typeof openFence === "string",
    "openFence must be a string or null",
  );
  assert.equal(typeof line, "string", "line must be a string");

  if (openFence === null) {
    const opener = matchLine(FENCE_OPEN_PATTERN, line);
    return opener === null ? null : (opener[1] ?? opener[2]);
  }
  const closer = matchLine(FENCE_CLOSE_PATTERN, line);
  const closes =
    closer !== null &&
    closer[1][0] === openFence[0] &&
    closer[1].length >= openFence.length;
  return closes ? null : openFence;
}

/**
 * Guard the generated section body against LLM drift: drop a leading version
 * heading if Communique emitted one, and demote stray H2 headings to H3 so they
 * stay nested below the canonical release heading.
 */
function normalizeCommuniqueBody(body) {
  assert.equal(typeof body, "string", "body must be a string");
  const withoutLeadingHeading = body
    .trim()
    .replace(/^#{1,3} \[?v?\d[^\n]*\n*/, "");
  const { lines, endings } = splitLines(withoutLeadingHeading);
  let openFence = null;
  return lines
    .map((line, i) => {
      const outsideFence = openFence === null;
      openFence = nextOpenFence(openFence, line);
      if (outsideFence && openFence === null && /^## /.test(line)) {
        return `### ${line.slice(3)}${endings[i]}`;
      }
      return `${line}${endings[i]}`;
    })
    .join("")
    .trim();
}

/**
 * Formats the CHANGELOG.md entry, release PR body entry, and release-please
 * GitHub Release notes. The heading intentionally omits `v`: release-please
 * parses merged release PR bodies expecting a digit after the optional `[`.
 */
function formatChangelogSection(version, isoDate, body) {
  assert.equal(typeof version, "string", "version must be a string");
  assert.notEqual(version, "", "version must not be empty");
  assert.equal(typeof isoDate, "string", "isoDate must be a string");
  assert.match(isoDate, /^\d{4}-\d{2}-\d{2}$/, "isoDate must be YYYY-MM-DD");

  const normalized = normalizeCommuniqueBody(body);
  const content =
    normalized === ""
      ? "- Maintenance release with no user-facing changes."
      : normalized;
  return `## [${version}] - ${isoDate}\n\n${content}`;
}

function todayIsoDate(now = new Date()) {
  return now.toISOString().slice(0, 10);
}

async function runCommuniqueBinary(args, env) {
  try {
    const { stderr } = await execFileAsync("communique", args, {
      env,
      maxBuffer: 16 * 1024 * 1024,
    });
    if (stderr.trim() !== "") {
      process.stderr.write(stderr);
    }
  } catch (error) {
    const stderr =
      error instanceof Object && "stderr" in error ? String(error.stderr) : "";
    throw new Error(
      `communique ${args.join(" ")} failed${stderr === "" ? "" : `:\n${stderr}`}`,
      { cause: error },
    );
  }
}

function releasePleaseNotesAreEmpty(notes) {
  assert.equal(typeof notes, "string", "notes must be a string");
  return notes.split("\n").length <= 1;
}

function createCommuniqueChangelogNotes(
  runCommunique = runCommuniqueBinary,
  env = process.env,
) {
  return {
    async buildNotes(commits, options) {
      const defaultNotes = await new DefaultChangelogNotes().buildNotes(
        commits,
        options,
      );
      if (releasePleaseNotesAreEmpty(defaultNotes)) {
        return defaultNotes;
      }

      assertLlmCredentials(env);
      const scratchDir = mkdtempSync(join(tmpdir(), "communique-notes-"));
      const outputFile = join(scratchDir, "notes.md");
      try {
        const args = buildCommuniqueArgs({
          repo: `${options.owner}/${options.repository}`,
          outputFile,
          previousTag: options.previousTag,
          model: env.COMMUNIQUE_MODEL,
        });
        await runCommunique(args, env);
        if (!existsSync(outputFile)) {
          throw new Error(
            `communique exited successfully but wrote no output file at ${outputFile}`,
          );
        }
        const body = readFileSync(outputFile, "utf8");
        return formatChangelogSection(options.version, todayIsoDate(), body);
      } finally {
        rmSync(scratchDir, { recursive: true, force: true });
      }
    },
  };
}

/**
 * Index of the first line at or after `start` matching `predicate` outside any
 * fenced code block, or -1. Fence state is tracked from the first line so
 * heading-like lines inside fences are never mistaken for real headings.
 */
function findLineOutsideFences(lines, start, predicate) {
  assert.ok(Array.isArray(lines), "lines must be an array");
  assert.equal(typeof start, "number", "start must be a number");
  assert.equal(typeof predicate, "function", "predicate must be a function");

  let openFence = null;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    // A fence line, or a line inside a fence, is never outside it.
    const outsideFence = openFence === null;
    openFence = nextOpenFence(openFence, line);
    if (outsideFence && openFence === null && i >= start && predicate(line)) {
      return i;
    }
  }
  return -1;
}

/**
 * Throws when a code fence that never closes hides a section. `updateContent` drops everything after the
 * Unreleased heading when no next section stands outside a fence. A fence that runs to the end of the text (it has
 * no closer, or its closer is shorter, uses the other marker, or has text after it) swallows every older release, and
 * the new changelog would silently lose them. A line that starts with `# ` or `## `, the runner's own section
 * boundary, inside such a fence is the sign of that loss. A fence that closes, or one that holds no such line, keeps
 * the old behavior: the draft is dropped and nothing else is lost.
 */
function assertNoSectionInUnclosedFence(lines) {
  assert.ok(Array.isArray(lines), "lines must be an array");

  let openFence = null;
  let openedAt = -1;
  for (let i = 0; i < lines.length; i += 1) {
    const wasOpen = openFence !== null;
    openFence = nextOpenFence(openFence, lines[i] ?? "");
    if (!wasOpen && openFence !== null) {
      openedAt = i;
    }
  }
  if (openFence === null) {
    return;
  }
  assert.notEqual(openedAt, -1, "an open fence has an opener");

  const hiddenAt = lines.findIndex(
    (line, i) => i > openedAt && NEXT_SECTION_PATTERN.test(line),
  );
  if (hiddenAt === -1) {
    return;
  }
  const show = (line) => JSON.stringify(line.slice(0, 80));
  throw new Error(
    `The Unreleased section has a code fence that never closes. Line ${openedAt + 1} opens it (${show(lines[openedAt])}), ` +
      `and line ${hiddenAt + 1} (${show(lines[hiddenAt])}) would start the next section. It stands inside the fence, so the updater would drop it and everything after it. ` +
      "Close the fence: a closing line uses the same character as the opener, at least as many of it, and has nothing after it but spaces or tabs.",
  );
}

function resolvePrettierBin(env = process.env, fileExists = existsSync) {
  if (env.PRETTIER_BIN !== undefined && env.PRETTIER_BIN !== "") {
    return env.PRETTIER_BIN;
  }
  if (fileExists(LOCAL_PRETTIER_BIN)) {
    return LOCAL_PRETTIER_BIN;
  }
  return "prettier";
}

function formatChangelogMarkdown(content) {
  assert.equal(typeof content, "string", "content must be a string");
  return execFileSync(
    resolvePrettierBin(),
    ["--stdin-filepath", "CHANGELOG.md"],
    {
      encoding: "utf8",
      input: content,
      maxBuffer: 16 * 1024 * 1024,
    },
  );
}

/**
 * Replaces release-please's stock CHANGELOG updater. It keeps `## [Unreleased]`
 * at the top, clears its draft body after Communique reconciles it into the
 * release entry, and inserts the new release directly below the anchor.
 */
class UnreleasedAwareChangelog {
  constructor(options) {
    assert.equal(typeof options, "object", "options must be an object");
    assert.equal(
      typeof options.changelogEntry,
      "string",
      "changelogEntry must be a string",
    );
    assert.notEqual(
      options.changelogEntry,
      "",
      "changelogEntry must not be empty",
    );
    this.changelogEntry = options.changelogEntry;
  }

  updateContent(content) {
    // Every line ending becomes LF, as CRLF already did.
    const { lines } = splitLines(content ?? "");
    const existing = lines.join("\n");
    const entry = this.changelogEntry.trim();

    const unreleasedIndex = findLineOutsideFences(lines, 0, (line) =>
      UNRELEASED_HEADING_PATTERN.test(line),
    );
    if (unreleasedIndex !== -1) {
      const head = lines.slice(0, unreleasedIndex + 1).join("\n");
      const nextIndex = findLineOutsideFences(
        lines,
        unreleasedIndex + 1,
        (line) => NEXT_SECTION_PATTERN.test(line),
      );
      if (nextIndex === -1) {
        // The draft is the last thing in the text, so nothing below the new entry survives. Make sure that no
        // fence that never closes hid an older release.
        assertNoSectionInUnclosedFence(lines);
      }
      const rest = nextIndex === -1 ? "" : lines.slice(nextIndex).join("\n");
      return formatChangelogMarkdown(joinSections(head, entry, rest));
    }

    // Self-heal a missing Unreleased anchor so Communique has draft space on
    // the next run.
    const titleIndex = findLineOutsideFences(lines, 0, (line) =>
      TITLE_PATTERN.test(line),
    );
    if (titleIndex !== -1) {
      const head = `${lines.slice(0, titleIndex + 1).join("\n")}\n\n## [Unreleased]`;
      return formatChangelogMarkdown(
        joinSections(head, entry, lines.slice(titleIndex + 1).join("\n")),
      );
    }
    return formatChangelogMarkdown(
      joinSections("# Changelog\n\n## [Unreleased]", entry, existing),
    );
  }
}

function joinSections(head, entry, rest) {
  const sections = [head.trimEnd(), entry];
  if (rest.trim() !== "") {
    sections.push(rest.trim());
  }
  return `${sections.join("\n\n")}\n`;
}

class CommuniqueSimpleStrategy extends Simple {
  async getBranchComponent() {
    return this.includeComponentInTag ? super.getBranchComponent() : undefined;
  }

  async buildUpdates(options) {
    const updates = await super.buildUpdates(options);
    return updates.map((update) =>
      update.updater instanceof Changelog
        ? {
            ...update,
            updater: new UnreleasedAwareChangelog({
              changelogEntry: update.updater.changelogEntry,
            }),
          }
        : update,
    );
  }
}

function formatReleaseOutputs(releases) {
  assert.ok(Array.isArray(releases), "releases must be an array");
  const tags = releases
    .filter((release) => release !== undefined)
    .map((release) => release.tagName);
  return {
    releases_created: tags.length > 0 ? "true" : "false",
    release_tags: tags.join(" "),
  };
}

function formatPullRequestOutputs(pullRequests) {
  assert.ok(Array.isArray(pullRequests), "pullRequests must be an array");
  const prs = pullRequests
    .filter((pullRequest) => pullRequest !== undefined)
    .map((pullRequest) => ({
      branch: pullRequest.headBranchName,
      title: pullRequest.title.toString(),
    }));
  return {
    prs_created: prs.length > 0 ? "true" : "false",
    pr_branches: prs.map((pr) => pr.branch).join(" "),
    pr_metadata: JSON.stringify(prs),
  };
}

function writeGithubOutputs(outputs) {
  const lines = Object.entries(outputs)
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");

  const outputPath = process.env.GITHUB_OUTPUT;
  if (outputPath === undefined || outputPath === "") {
    process.stdout.write(`${lines}\n`);
    return;
  }
  appendFileSync(outputPath, `${lines}\n`);
}

/**
 * Dry-run aid: applies the candidate PR's CHANGELOG.md update to the local
 * working-tree copy so maintainers can inspect the generated result.
 */
function previewChangelog(updates) {
  const changelogUpdate = updates.find(
    (update) => update.updater instanceof UnreleasedAwareChangelog,
  );
  if (changelogUpdate === undefined) {
    return undefined;
  }

  let current;
  try {
    current = readFileSync(changelogUpdate.path, "utf8");
  } catch {
    current = undefined;
  }
  return changelogUpdate.updater.updateContent(current);
}

function requireEnv(name) {
  const value = process.env[name];
  if (value === undefined || value === "") {
    throw new Error(`${name} must be set`);
  }
  return value;
}

async function main() {
  const dryRun = process.argv.includes("--dry-run");
  const token = requireEnv("GITHUB_TOKEN");
  const repository = requireEnv("GITHUB_REPOSITORY");
  const [owner, repo, extra] = repository.split("/");
  if (
    owner === undefined ||
    owner === "" ||
    repo === undefined ||
    repo === "" ||
    extra !== undefined
  ) {
    throw new Error(`GITHUB_REPOSITORY must be owner/repo, got: ${repository}`);
  }

  registerChangelogNotes("communique", () => createCommuniqueChangelogNotes());
  registerReleaseType(
    "simple",
    (options) => new CommuniqueSimpleStrategy(options),
  );

  const github = await GitHub.create({ owner, repo, token });
  // Useful for --dry-run previews from a feature branch: release-please reads
  // config and manifest files from the remote target branch, not this checkout.
  const targetBranch =
    process.env.RELEASE_PLEASE_TARGET_BRANCH ?? github.repository.defaultBranch;
  const manifest = await Manifest.fromManifest(github, targetBranch);

  if (dryRun) {
    const candidateReleases = await manifest.buildReleases();
    const candidatePullRequests = await manifest.buildPullRequests();
    process.stdout.write(
      `${JSON.stringify(
        {
          releases: candidateReleases.map((release) => ({
            tag: release.tag.toString(),
            sha: release.sha,
            notes: release.notes,
          })),
          pullRequests: candidatePullRequests.map((pullRequest) => ({
            title: pullRequest.title.toString(),
            headBranchName: pullRequest.headRefName,
            version: pullRequest.version?.toString(),
            body: pullRequest.body.toString(),
            changelogPreview: previewChangelog(pullRequest.updates),
          })),
        },
        null,
        2,
      )}\n`,
    );
    return;
  }

  // Releases first, then PRs — the same ordering as release-please-action.
  const releases = await manifest.createReleases();
  // Write release outputs before rebuilding PR notes so the workflow can still
  // dispatch release-note generation if a later LLM call fails after a tag was
  // already created.
  const releaseOutputs = formatReleaseOutputs(releases);
  writeGithubOutputs(releaseOutputs);

  const pullRequests = await manifest.createPullRequests();
  const pullRequestOutputs = formatPullRequestOutputs(pullRequests);
  writeGithubOutputs(pullRequestOutputs);

  process.stdout.write(
    `release-please: releases=[${releaseOutputs.release_tags}] prs=[${pullRequestOutputs.pr_branches}]\n`,
  );
}

module.exports = {
  CommuniqueSimpleStrategy,
  UnreleasedAwareChangelog,
  assertLlmCredentials,
  buildCommuniqueArgs,
  createCommuniqueChangelogNotes,
  findLineOutsideFences,
  formatChangelogMarkdown,
  formatChangelogSection,
  formatPullRequestOutputs,
  formatReleaseOutputs,
  normalizeCommuniqueBody,
  resolvePrettierBin,
  releasePleaseNotesAreEmpty,
  todayIsoDate,
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}

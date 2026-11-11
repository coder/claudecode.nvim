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

const commonmark = require("commonmark");
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

// The lines that the update anchors on, and no others: an H2 or H3 at the start of a line, one space after the marks,
// the text `[Unreleased]` or `Unreleased`, and nothing but blanks after it. These are the lines that the runner anchored
// on before it used a parser, and `## [Unreleased]` and `## Unreleased` are the lines that Communique 1.1.3 reads a
// draft under. The update drops the draft, so it must not drop a draft that Communique never read. Communique also
// reads `## [Unreleased](...)`, which the runner never anchored on, and the runner anchored on `## [Unreleased` and
// `## Unreleased]`, which Communique does not read, so neither is an anchor. Any other spelling is no anchor: bold,
// emphasis or code, an escape, `[Unreleased][]`, two spaces or a tab after the marks, an indent, a closing `##`, a
// setext heading, other text, or another case. Communique reads no draft under an H3 anchor either, so a non-empty one
// is refused (see `assertDraftIsPlain`).
const UNRELEASED_LINE_PATTERN = /^#{2,3} (?:\[Unreleased\]|Unreleased)[ \t]*$/;
const TITLE_PATTERN = /^# .+$/;
// The nodes that an Unreleased draft can hold. A heading is not one of them: only a subsection heading is allowed
// (see `assertDraftIsPlain`). The update drops the draft, so it drops only what it reads.
const DRAFT_NODE_TYPES = new Set([
  "paragraph",
  "list",
  "item",
  "text",
  "softbreak",
  "linebreak",
  "code",
  "emph",
  "strong",
  "link",
  "image",
  "html_inline",
]);
// A line that starts with `## ` once the blanks that Communique removes are gone. Communique 1.1.3 trims a line with
// Rust's `trim` (U+0009 to U+000D, a space, U+0085, U+00A0, U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F
// and U+3000), and it ends its draft at a trimmed line `## <version>`. CommonMark keeps most of those blanks as text,
// so such a line is not a heading to the update.
const COMMUNIQUE_SECTION_LINE_PATTERN =
  /^[\t\n\v\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]*## /;
// A list item line that holds a marker and nothing else (`-`, `*`, `+`, `1.`, `2)`, or `- -`).
const EMPTY_ITEM_LINE_PATTERN = /^[ \t]*(?:(?:[-*+]|\d{1,9}[.)])[ \t]*)+$/;
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
 * The top-level blocks of `text`, read by commonmark.js. The Unreleased update reads the changelog with a real
 * Markdown parser, because a reader of single lines cannot tell an HTML block, a setext heading, a list item, a block
 * quote or an indented code block from a section heading. Nested blocks are the children of these.
 */
function parseBlocks(text) {
  assert.equal(typeof text, "string", "text must be a string");
  const blocks = [];
  for (
    let block = new commonmark.Parser().parse(text).firstChild;
    block;
    block = block.next
  ) {
    blocks.push(block);
  }
  return blocks;
}

/**
 * The text of a heading: its inline literals, with every run of blanks as one space. A link counts as its text in
 * brackets, so `[0.3.0]` reads the same whether or not a link definition below it makes it a link.
 */
function headingText(heading) {
  assert.equal(heading.type, "heading", "node must be a heading");
  let text = "";
  const walker = heading.walker();
  for (let event = walker.next(); event; event = walker.next()) {
    const { entering, node } = event;
    if (node.type === "link") {
      text += entering ? "[" : "]";
    } else if (entering && node.literal !== null) {
      text += node.literal;
    }
  }
  return text.replace(/\s+/g, " ").trim();
}

/**
 * `"<level> <text>"` for each heading that is a direct child of the document. A heading inside a list item or a block
 * quote is not one: it is not a section of the changelog.
 */
function topLevelHeadings(text) {
  return parseBlocks(text)
    .filter((block) => block.type === "heading")
    .map((block) => `${block.level} ${headingText(block)}`);
}

/**
 * Where the Unreleased draft is in `lines`, or null when there is no Unreleased heading. The anchor is the first
 * top-level heading of level 2 or 3 whose own line is one of the lines of `UNRELEASED_LINE_PATTERN`. The draft is the
 * blocks after it, up to the next top-level heading of the anchor's level or a higher one (an H1 or H2 after an H2
 * anchor), or to the end of the text. An H3 under an H2 anchor is a subsection of the draft, whatever it says. `level`
 * is the level of the anchor. `headEnd` is the last line of the anchor and `restStart` the first line after the draft,
 * both numbered from 1. `restStart` is null when the draft runs to the end of the text, and `end` is the heading that
 * ends the draft, or null.
 */
function findUnreleasedDraft(lines) {
  assert.ok(Array.isArray(lines), "lines must be an array");
  const blocks = parseBlocks(lines.join("\n"));
  const anchor = blocks.findIndex(
    (block) =>
      block.type === "heading" &&
      UNRELEASED_LINE_PATTERN.test(lines[block.sourcepos[0][0] - 1]),
  );
  if (anchor === -1) {
    return null;
  }
  const { level } = blocks[anchor];
  const next = blocks.findIndex(
    (block, i) =>
      i > anchor && block.type === "heading" && block.level <= level,
  );
  return {
    level,
    blocks: blocks.slice(anchor + 1, next === -1 ? blocks.length : next),
    headEnd: blocks[anchor].sourcepos[1][0],
    restStart: next === -1 ? null : blocks[next].sourcepos[0][0],
    end: next === -1 ? null : blocks[next],
  };
}

/**
 * Throws unless the Unreleased draft holds only paragraphs, lists and H3 headings, with their inline text.
 * `updateContent` drops the draft, so it drops only what it reads. A code block, an HTML block, a block quote, a
 * thematic break or a heading of another level is refused, and so is a line that no paragraph or heading holds (a link
 * reference definition leaves no node). An empty list item is a marker alone, and it is read. Each of the refused
 * shapes can end a section where a reader of lines sees none, hide the lines after it, or hold an older release. The
 * error names the line and the node type, and it comes before anything is formatted. A code fence keeps the error of
 * the fence check that came first. A draft under an H3 anchor is refused whatever it holds, because Communique reads a
 * draft only under an H2 anchor, and the update would drop text that nobody reconciled into the new entry. An empty
 * draft under an H3 anchor is fine. A draft line that starts with `## ` once the blanks that Communique trims are
 * removed (a no-break space before `## [0.4.1]`, for example) is refused, because Communique ends its draft there and
 * reads nothing below it. The heading that ends the draft must be a one-line heading with text: an empty heading or a
 * setext heading is refused, because Communique reads the text below it and the update would keep it. `draft` is the
 * result of `findUnreleasedDraft`, and `lines` the lines of the text it
 * read. The cost: a draft with a code block, a quote, HTML, a rule, a deeper heading or a link definition is refused
 * until a maintainer edits it.
 */
function assertDraftIsPlain(lines, draft) {
  assert.ok(Array.isArray(lines), "lines must be an array");
  assert.ok(Array.isArray(draft.blocks), "draft must hold blocks");
  const shownLine = (line) =>
    JSON.stringify((lines[line - 1] ?? "").slice(0, 80));
  if (draft.level !== 2 && draft.blocks.length > 0) {
    const line = draft.blocks[0].sourcepos[0][0];
    throw new Error(
      `The Unreleased draft sits under a level ${draft.level} heading. Line ${line} starts it: ${shownLine(line)}. ` +
        "Communique reads a draft only under `## [Unreleased]` or `## Unreleased`, so the update would drop text that nobody reconciled into the new entry. " +
        "Move the draft under `## [Unreleased]`, or remove it.",
    );
  }
  const covered = new Set();
  for (const block of draft.blocks) {
    const walker = block.walker();
    for (let event = walker.next(); event; event = walker.next()) {
      const { entering, node } = event;
      if (!entering) {
        continue;
      }
      const isSubsection = node.type === "heading" && node.level === 3;
      if (!isSubsection && !DRAFT_NODE_TYPES.has(node.type)) {
        // An inline node has no position: its block does.
        let positioned = node;
        while (positioned.sourcepos === undefined) {
          positioned = positioned.parent;
        }
        const line = positioned.sourcepos[0][0];
        if (node.type === "code_block" && node.info !== null) {
          throw new Error(
            `The Unreleased draft has a code fence. Line ${line} opens it: ${shownLine(line)}. ` +
              "The update drops the draft, and a fence that does not close where you meant would drop the older releases below it too. " +
              "Move the code block out of the Unreleased draft.",
          );
        }
        const kind =
          node.type === "heading"
            ? `heading (level ${node.level})`
            : node.type === "code_block"
              ? "code_block (indented)"
              : node.type;
        throw new Error(
          `The Unreleased draft has a node that the update does not read: ${kind}. Line ${line} starts it: ${shownLine(line)}. ` +
            "The update drops the draft, so it reads only paragraphs, lists and level 3 headings there. " +
            "Move it out of the Unreleased draft.",
        );
      }
      if (node.type === "paragraph" || node.type === "heading") {
        for (
          let line = node.sourcepos[0][0];
          line <= node.sourcepos[1][0];
          line += 1
        ) {
          covered.add(line);
        }
      } else if (
        node.type === "item" &&
        EMPTY_ITEM_LINE_PATTERN.test(lines[node.sourcepos[0][0] - 1] ?? "")
      ) {
        // The line of a marker with nothing after it holds no paragraph.
        covered.add(node.sourcepos[0][0]);
      }
    }
  }
  const last = draft.restStart === null ? lines.length : draft.restStart - 1;
  for (let line = draft.headEnd + 1; line <= last; line += 1) {
    if (!/^[ \t]*$/.test(lines[line - 1] ?? "") && !covered.has(line)) {
      throw new Error(
        `The Unreleased draft has a line that no paragraph or heading holds. Line ${line}: ${shownLine(line)}. ` +
          "A link reference definition is one. The update drops the draft, so it refuses a line that it cannot read. " +
          "Move it out of the Unreleased draft.",
      );
    }
    if (COMMUNIQUE_SECTION_LINE_PATTERN.test(lines[line - 1] ?? "")) {
      throw new Error(
        `The Unreleased draft has a line that Communique reads as a section heading. Line ${line}: ${shownLine(line)}. ` +
          "Communique ends its draft there, so it never reads the lines below it, and the update would drop them. " +
          "Move it out of the Unreleased draft, or write it as a paragraph.",
      );
    }
  }
  // The heading that ends the draft is a one-line heading with text. Communique reads the text below any other end
  // (an empty heading or a setext heading) as part of its draft and folds it into the new entry, and the update keeps
  // it, so it would show twice.
  if (
    draft.end !== null &&
    (draft.end.sourcepos[0][0] !== draft.end.sourcepos[1][0] ||
      headingText(draft.end) === "")
  ) {
    const line = draft.end.sourcepos[0][0];
    throw new Error(
      `The Unreleased draft ends at a heading that is empty or a setext heading. Line ${line} starts it: ${shownLine(line)}. ` +
        "Communique reads the text below it as draft too and folds it into the new entry, so the update would write that text twice. " +
        "Write the heading on one line with `## ` and its text, or move the text out of the Unreleased draft.",
    );
  }
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
 * Formats `markdown` and checks that the formatter kept the headings of the text. `markdown` is the head of the
 * changelog, the new `entry`, and the older releases `kept`. The last top-level headings of the formatted text must be,
 * in this order and with the same levels and text, the top-level headings of the entry (read alone) and then those of
 * the kept text (read alone). A new entry with a code fence or an HTML comment that never closes, for example, swallows
 * the older releases below it, and the formatter then closes the fence at the end of the text and writes them as code.
 * A formatter that moves a setext heading into a list item has the same result. A heading in the entry that repeats an
 * older release does not hide the loss, because the count and the order must match too. The check refuses these
 * before anything is written. A heading inside a list item or a block quote is not a section, so it does not count.
 */
function formatKeepingHeadings(markdown, entry, kept) {
  assert.equal(typeof markdown, "string", "markdown must be a string");
  assert.equal(typeof entry, "string", "entry must be a string");
  assert.equal(typeof kept, "string", "kept must be a string");
  const formatted = formatChangelogMarkdown(markdown);
  const expected = [...topLevelHeadings(entry), ...topLevelHeadings(kept)];
  const found = topLevelHeadings(formatted);
  const tail = found.slice(Math.max(0, found.length - expected.length));
  const changed = expected.findIndex((heading, i) => heading !== tail[i]);
  if (changed !== -1) {
    throw new Error(
      "The update would change the older releases. After the formatter runs, the headings of the new entry and the older releases are not the headings that were there: " +
        `expected ${JSON.stringify(expected[changed])} but found ${JSON.stringify(tail[changed] ?? null)}. ` +
        "The new entry or the older releases hold Markdown that the formatter rewrites, such as a code fence that never closes, so the update refuses to write it.",
    );
  }
  return formatted;
}

/**
 * Replaces release-please's stock CHANGELOG updater. It keeps `## [Unreleased]`
 * at the top, clears its draft body after Communique reconciles it into the
 * release entry, and inserts the new release directly below the anchor.
 *
 * The draft is read with commonmark.js. The anchor is a heading line that Communique reads a draft under (see
 * `UNRELEASED_LINE_PATTERN`). The draft is the blocks from the anchor to the next top-level heading of the same level or
 * a higher one, or to the end of the text. It can hold only paragraphs, lists and H3 headings (see
 * `assertDraftIsPlain`), and the update refuses anything else before it formats. A draft under an H3 anchor is
 * refused, because Communique reads none. An H3 heading directly under `## [Unreleased]` is a subsection of the draft
 * whatever it says, so `### [0.3.0]` there is dropped with the draft. After the formatter runs, the headings of the new
 * entry and the older releases must be unchanged (see `formatKeepingHeadings`).
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

    const draft = findUnreleasedDraft(lines);
    if (draft !== null) {
      assertDraftIsPlain(lines, draft);
      const head = lines.slice(0, draft.headEnd).join("\n");
      const rest =
        draft.restStart === null
          ? ""
          : lines.slice(draft.restStart - 1).join("\n");
      return formatKeepingHeadings(
        joinSections(head, entry, rest),
        entry,
        rest,
      );
    }

    // Self-heal a missing Unreleased anchor so Communique has draft space on
    // the next run.
    const titleIndex = findLineOutsideFences(lines, 0, (line) =>
      TITLE_PATTERN.test(line),
    );
    if (titleIndex !== -1) {
      const head = `${lines.slice(0, titleIndex + 1).join("\n")}\n\n## [Unreleased]`;
      const rest = lines.slice(titleIndex + 1).join("\n");
      return formatKeepingHeadings(
        joinSections(head, entry, rest),
        entry,
        rest,
      );
    }
    return formatKeepingHeadings(
      joinSections("# Changelog\n\n## [Unreleased]", entry, existing),
      entry,
      existing,
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

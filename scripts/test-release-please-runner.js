#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const { execFile, execFileSync, spawnSync } = require("node:child_process");
const {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} = require("node:fs");
const http = require("node:http");
const { tmpdir } = require("node:os");
const { delimiter, join } = require("node:path");
const { promisify } = require("node:util");
const commonmark = require("commonmark");

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
  // CommonMark reads an info string literally for this rule: an escape or a character reference changes nothing.
  assert.equal(
    outside(["```\\`x", "## Real", "```", "## Real"]),
    1,
    "a backslash before a backtick does not let a backtick fence carry it",
  );
  assert.equal(
    outside(["```&#96;", "## Real", "```", "## Real"]),
    3,
    "a character reference for a backtick is not a backtick in the info string",
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
  // nothing, so each row has as many trailing blanks as indent. The lengths run from 3 to 10, then 100 and 101, 255
  // to 257, and 1,000 and 1,001, to catch a cap on a marker run, for example at 4, 100, 255 or 1,000.
  const lengths = [
    3, 4, 5, 6, 7, 8, 9, 10, 100, 101, 255, 256, 257, 1000, 1001,
  ];
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
  // Every UTF-16 code unit but LF and CR, so no single character is left out.
  const characters = [];
  for (let code = 0; code <= 0xffff; code += 1) {
    const character = String.fromCharCode(code);
    if (character !== "\n" && character !== "\r") {
      characters.push(character);
    }
  }
  for (const marker of ["`", "~"]) {
    const fence = marker.repeat(3);
    for (const character of characters.filter((other) => other !== marker)) {
      const name = `U+${character.charCodeAt(0).toString(16).padStart(4, "0")}`;
      assert.equal(
        outside([fence + character, "## Real", fence, "## Real"]),
        3,
        `a fence of ${marker} can carry ${name} in its info string`,
      );
      if (character !== " " && character !== "\t") {
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
        // A blank next to it changes nothing.
        for (const blank of [" ", "\t"]) {
          for (const suffix of [blank + character, character + blank]) {
            assert.equal(
              outside([
                fence,
                "## Real",
                fence + suffix,
                "## Real",
                fence,
                "## Real",
              ]),
              5,
              `${JSON.stringify(suffix)} after a closing fence of ${marker} keeps the fence open`,
            );
          }
        }
      }
      // Then a marker after it: a backtick opener cannot carry a backtick, wherever it stands, and a closer cannot
      // carry any marker.
      assert.equal(
        outside([fence + character + marker, "## Real", fence, "## Real"]),
        marker === "`" ? 1 : 3,
        `${name} then a ${marker} after the markers of a ${marker} opener`,
      );
      assert.equal(
        outside([
          fence,
          "## Real",
          fence + character + marker,
          "## Real",
          fence,
          "## Real",
        ]),
        5,
        `${name} then a ${marker} after a closing fence of ${marker} keeps the fence open`,
      );
    }
  }
  assert.equal(
    outside(["```", "## Real", "``` `", "## Real", "```", "## Real"]),
    5,
    "a backtick after a blank keeps the fence open",
  );
  assert.equal(
    outside(["~~~", "## Real", "~~~ ~", "## Real", "~~~", "## Real"]),
    5,
    "a tilde after a blank keeps the fence open",
  );
  // Only spaces are indent. Any other code unit before the markers keeps a line from opening or closing a fence.
  for (const marker of ["`", "~"]) {
    const fence = marker.repeat(3);
    for (const character of characters.filter(
      (other) => other !== marker && other !== " ",
    )) {
      const name = `U+${character.charCodeAt(0).toString(16).padStart(4, "0")}`;
      // Also after up to three spaces: the code unit ends the indent wherever it stands.
      for (const spaces of ["", " ", "  ", "   "]) {
        assert.equal(
          outside([spaces + character + fence, "## Real", fence, "## Real"]),
          1,
          `${name} after ${spaces.length} spaces before a fence of ${marker} is not indent for an opener`,
        );
        assert.equal(
          outside([
            fence,
            "## Real",
            spaces + character + fence,
            "## Real",
            fence,
            "## Real",
          ]),
          5,
          `${name} after ${spaces.length} spaces before a fence of ${marker} is not indent for a closer`,
        );
      }
    }
  }
  // An info string has no length limit, and neither has a marker run.
  for (const marker of ["`", "~"]) {
    const fence = marker.repeat(3);
    assert.equal(
      outside([fence + "x".repeat(100_000), "## Real", fence, "## Real"]),
      3,
      `a fence of ${marker} can carry an info string of 100,000 code units`,
    );
    assert.equal(
      outside([
        marker.repeat(100_000),
        "## Real",
        marker.repeat(99_999),
        "## Real",
        marker.repeat(100_000),
        "## Real",
      ]),
      5,
      `a fence of 100,000 ${marker} needs a closer of 100,000`,
    );
  }
  // A backtick after U+2028 or U+2029 is still a backtick in the info string, so the line opens no fence. The
  // CommonMark spec says so, and markdown-it 14 agrees. (commonmark.js 0.31.2 gets this case wrong.)
  for (const separator of ["\u2028", "\u2029"]) {
    assert.equal(
      outside([`\`\`\`x${separator}\``, "## Real"]),
      1,
      `a backtick after U+${separator.charCodeAt(0).toString(16)} keeps a backtick line from opening a fence`,
    );
  }

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
  // From every `start`, the search finds the first line outside a fence at or after it, however far back a fence
  // opened.
  const fenced = ["a", "```", "x", "```", "b", "~~~", "y", "~~~", "c"];
  for (let start = 0; start <= fenced.length; start += 1) {
    assert.equal(
      runner.findLineOutsideFences(fenced, start, anyLine),
      [0, 4, 8].find((line) => line >= start) ?? -1,
      `the first line outside a fence from line ${start}`,
    );
  }
  // A fence with no lines between its opener and closer, right after another fence, still closes.
  assert.equal(
    outside(["```", "x", "```", "```", "```", "## Real"]),
    5,
    "an empty fence right after a closed fence opens and closes",
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
  // A line ends with LF, CR, or CRLF, and the body keeps each ending as it is.
  for (const marker of ["```", "~~~"]) {
    for (const ending of ["\n", "\r\n", "\r"]) {
      assert.equal(
        runner.normalizeCommuniqueBody(
          ["## A", marker, "## inside", marker, "## B"].join(ending),
        ),
        ["### A", marker, "## inside", marker, "### B"].join(ending),
        `${marker} fence with ${JSON.stringify(ending)} line endings`,
      );
    }
    assert.equal(
      runner.normalizeCommuniqueBody(
        `## A\r\n${marker}\r## inside\n${marker}\r\n## B`,
      ),
      `### A\r\n${marker}\r## inside\n${marker}\r\n### B`,
      `${marker} fence with mixed line endings`,
    );
  }
}

/**
 * Runs `fn` with a formatter that prints its input, so a test sees the text that `updateContent` builds. prettier
 * rewrites some generated documents (it dedents a line that CommonMark reads as a paragraph continuation, for
 * example), and each prettier run takes far longer than the script.
 */
function withIdentityFormatter(fn) {
  const directory = mkdtempSync(join(tmpdir(), "identity-formatter-"));
  const formatter = join(directory, "format.sh");
  writeFileSync(formatter, "#!/bin/sh\ncat\n", { mode: 0o755 });
  const previousFormatter = process.env.PRETTIER_BIN;
  process.env.PRETTIER_BIN = formatter;
  try {
    return fn();
  } finally {
    if (previousFormatter === undefined) {
      delete process.env.PRETTIER_BIN;
    } else {
      process.env.PRETTIER_BIN = previousFormatter;
    }
    rmSync(directory, { recursive: true, force: true });
  }
}

async function testUnreleasedUpdaterFences() {
  const entry = "## [0.4.0] - 2026-06-15\n\n* Added x";
  const released =
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n";
  const update = (content) =>
    new runner.UnreleasedAwareChangelog({
      changelogEntry: entry,
    }).updateContent(content);
  const previous = "\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n";

  // Each case is [existing changelog, updated changelog].
  const cases = [];
  // A fence in the draft is refused, whatever it holds and wherever it closes: a four-backtick fence that holds a
  // shorter fence, a tilde fence that holds backticks, text right after a closing fence, and a short fence inside a
  // long one. Each case is [existing changelog, the line that opens the fence].
  const refused = [];
  for (const [open, close] of [
    ["````md", "````"],
    ["~~~md", "~~~"],
  ]) {
    refused.push([
      `# Changelog\n\n## [Unreleased]\n\n${open}\n\`\`\`\n## Not a heading\n${close}${previous}`,
      open,
    ]);
  }
  refused.push([
    `# Changelog\n\n## [Unreleased]\n\n\`\`\`text\nExample\n\`\`\`\nText after the fence${previous}`,
    "```text",
  ]);
  refused.push([
    `# Changelog\n\n## [Unreleased]\n\n\`\`\`\`\n\`\`\`\n## Not a release\n\`\`\`\`${previous}`,
    "````",
  ]);
  // Without an Unreleased heading the entry goes under the title, or under a new title.
  cases.push([`# Changelog${previous}`, released]);
  cases.push([
    "Existing text\n\nMore text\n",
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\nExisting text\n\nMore text\n",
  ]);

  // A line ends with LF, CR, or CRLF. A bare CR ends a fence line like the others, and the
  // updated changelog has LF endings only.
  for (const ending of ["\n", "\r\n", "\r"]) {
    for (const [existing, updated] of cases) {
      assert.equal(
        update(existing.replace(/\n/g, ending)),
        updated,
        `${JSON.stringify(existing)} with ${JSON.stringify(ending)} line endings`,
      );
    }
    for (const [existing, opener] of refused) {
      assert.throws(
        () => update(existing.replace(/\n/g, ending)),
        { message: refusal(5, opener) },
        `${JSON.stringify(existing)} with ${JSON.stringify(ending)} line endings`,
      );
    }
  }

  // An Unreleased heading inside a fence is not the anchor of the update. Communique reads it as one, because it does
  // not parse Markdown, and it refuses a file with two anchors. So the update refuses the text as well, and it does not
  // keep a second Unreleased heading. With bare CR line breaks Communique reads no heading at all.
  const fencedAnchor =
    "# Changelog\n\n````text\n```\n## [Unreleased]\n````\n\n## [Unreleased]\n\n- Draft\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n";
  for (const ending of ["\n", "\r\n", "\r"]) {
    assert.throws(
      () =>
        withMissingFormatter(() => update(fencedAnchor.replace(/\n/g, ending))),
      {
        message: anchorMismatchRefusal(
          { number: 8, line: "## [Unreleased]" },
          ending === "\r" ? null : { number: 5, line: "## [Unreleased]" },
        ),
      },
      `an Unreleased heading in a fence, with ${JSON.stringify(ending)} line endings`,
    );
  }

  // One bare CR in an LF file: right after a closing fence, and inside an opener line. Each one ends a line, so the
  // fence opens on line 5 and the draft is refused.
  assert.throws(
    () =>
      update(
        "# Changelog\n\n## [Unreleased]\n\n```text\nExample\n```\rText after the fence\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n",
      ),
    { message: refusal(5, "```text") },
  );
  assert.throws(
    () =>
      update(
        "# Changelog\n\n## [Unreleased]\n\n````\r```\n## Not a release\n````\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n",
      ),
    { message: refusal(5, "````") },
  );

  // Only LF, CR and CR LF end a line. Other line-like characters stay inside the line, so no fence opens here.
  for (const character of ["\u2028", "\u2029", "\u0085", "\f", "\v"]) {
    assert.equal(
      update(
        `# Changelog\n\n## [Unreleased]\n\nNote${character}\`\`\`${previous}`,
      ),
      released,
      `U+${character.codePointAt(0).toString(16).padStart(4, "0")} does not end a line`,
    );
  }

  // `updateContent` splits the text itself, so every other code unit must stay inside its line too. One text holds a
  // line "Note<unit>```" for each code unit but LF and CR. If any unit ended a line, a fence would open and swallow the
  // next release.
  withIdentityFormatter(() => {
    const noteLines = [];
    for (let code = 0; code <= 0xffff; code += 1) {
      if (code !== 0x0a && code !== 0x0d) {
        noteLines.push(`Note${String.fromCharCode(code)}\`\`\``);
      }
    }
    assert.equal(
      update(
        `# Changelog\n\n## [Unreleased]\n\n${noteLines.join("\n")}${previous}`,
      ),
      // The formatter does not turn the `*` bullet of `entry` into `-`.
      released.replace("- Added x", "* Added x"),
      "no code unit but LF and CR ends a line in updateContent",
    );
  });

  // A text without a line ending, and a missing changelog file, still work.
  // Without a title or an Unreleased heading, CR CR LF is still two line endings.
  assert.equal(
    update("```\rx\r\r\ny\r```\r"),
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n```\nx\n\ny\n```\n",
  );
  assert.equal(runner.normalizeCommuniqueBody("- Added x"), "- Added x");
  assert.equal(
    update(undefined),
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n",
  );

  // No code unit but LF and CR ends a line, so the backticks after it never open a fence.
  for (let code = 0; code <= 0xffff; code += 1) {
    const character = String.fromCharCode(code);
    if (character === "\n" || character === "\r") {
      continue;
    }
    assert.equal(
      runner.normalizeCommuniqueBody(`## A\nNote${character}\`\`\`\n## B`),
      `### A\nNote${character}\`\`\`\n### B`,
      `U+${code.toString(16).padStart(4, "0")} does not end a line`,
    );
  }

  // A CR after an LF, two CRs before an LF, and a CR LF after an LF are separate line endings: each one ends a line,
  // so the fenced block keeps its blank line.
  for (const inside of ["x\n\ry", "x\r\r\ny", "x\n\r\ny"]) {
    assert.equal(
      update(
        `# Changelog\n\n## [Unreleased]\n\n## [0.3.0] - 2025-09-15\n\n\`\`\`\n${inside}\n\`\`\`\n`,
      ),
      released.replace("- Previous", "```\nx\n\ny\n```"),
      `${JSON.stringify(inside)} holds two line endings`,
    );
  }
}

/**
 * The error of `updateContent` for a draft that holds a code fence. Lines are numbered from 1, and a line shows its
 * first 80 code units.
 */
function refusal(lineNumber, line) {
  return (
    `The Unreleased draft has a code fence. Line ${lineNumber} opens it: ${JSON.stringify(line.slice(0, 80))}. ` +
    "The update drops the draft, and a fence that does not close where you meant would drop the older releases below it too. " +
    "Move the code block out of the Unreleased draft."
  );
}

/**
 * Runs `fn` with a formatter that does not exist. A refusal must come before the formatter runs, so a test that
 * expects one fails with ENOENT instead if the formatter runs first.
 */
function withMissingFormatter(fn) {
  const directory = mkdtempSync(join(tmpdir(), "missing-formatter-"));
  const previousFormatter = process.env.PRETTIER_BIN;
  process.env.PRETTIER_BIN = join(directory, "no-such-prettier");
  try {
    return fn();
  } finally {
    if (previousFormatter === undefined) {
      delete process.env.PRETTIER_BIN;
    } else {
      process.env.PRETTIER_BIN = previousFormatter;
    }
    rmSync(directory, { recursive: true, force: true });
  }
}

async function testUnreleasedDraftFenceGuard() {
  const entry = "## [0.4.0] - 2026-06-15\n\n* Added x";
  const updateWith = (changelogEntry, content) =>
    new runner.UnreleasedAwareChangelog({ changelogEntry }).updateContent(
      content,
    );
  const update = (content) => updateWith(entry, content);
  const head = "# Changelog\n\n## [Unreleased]\n\n";
  const release = "## [0.3.0] - 2025-09-15";
  const previous = `\n\n${release}\n\n- Previous\n`;
  const released =
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n";
  const entryOnly =
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n";
  // The line of a text, numbered from 1.
  const lineOf = (text, line) => text.split(/\r\n|\r|\n/).indexOf(line) + 1;
  // `update` refuses before the formatter runs, and the error names the line that opens the fence.
  const refuses = (text, opener, name, run = update) => {
    assert.ok(lineOf(text, opener) > 0, `${name}: the text holds the opener`);
    assert.throws(
      () => withMissingFormatter(() => run(text)),
      { message: refusal(lineOf(text, opener), opener) },
      name,
    );
  };
  // A frozen copy of the released sections of the real changelog (0.4.0 and older), under an empty draft. The tests
  // never read CHANGELOG.md: its top changes (a staged draft, a release PR), and an edit of a released section changes
  // how Prettier wraps or leaves alone the code of an html or vue fence, which the reflow cases below depend on. The copy
  // is the text of the real file when the test was written, and it is a fixed point of Prettier.
  const realHead = "# Changelog\n\n## [Unreleased]\n";
  const releasedSections = readFileSync(
    join(__dirname, "fixtures", "changelog-released.md"),
    "utf8",
  );
  assert.ok(
    releasedSections.startsWith("## [0.4.0] - 2026-11-09\n"),
    "the fixture starts at 0.4.0",
  );
  const real = `${realHead}\n${releasedSections}`;

  // A draft fence that CommonMark does not close runs to the end of the text, and it holds every older release
  // below it. The updater must not write a changelog without that release, whatever shape the fence has.
  // Each shape is [name, the line that opens the fence, the same line after prettier, the draft]. Prettier writes a
  // longer opener when the fence holds a line of backticks, and backticks for a tilde fence.
  const stayOpen = [
    ["a fence with no closer", "```text", "```text", "```text\nDraft\n"],
    [
      "a closer that is shorter than the opener",
      "````text",
      "````text",
      "````text\nDraft\n```\n",
    ],
    [
      "a closer of the other marker",
      "```text",
      "```text",
      "```text\nDraft\n~~~\n",
    ],
    [
      "a closer with text after it",
      "```text",
      "````text",
      "```text\nDraft\n``` done\n",
    ],
    [
      "a four-backtick fence with no closer",
      "````md",
      "```md",
      "````md\nDraft\n",
    ],
    ["a tilde fence with no closer", "~~~text", "```text", "~~~text\nDraft\n"],
  ];
  // A code block in the older release has a bare closer, and that line can close the draft fence. No fence is open at
  // the end then, but the older release still sits inside the draft fence.
  const olderWithCode =
    "\n\n## [0.3.0] - 2025-09-15\n\n```js\nconsole.log(1);\n```\n\n- Previous\n";
  for (const [name, opener, formattedOpener, draft] of stayOpen) {
    const raw = `${head}${draft}${previous}`;
    for (const ending of ["\n", "\r\n", "\r"]) {
      refuses(
        raw.replace(/\n/g, ending),
        opener,
        `${name}, ${JSON.stringify(ending)} endings`,
      );
    }
    refuses(
      `${head}${draft}${olderWithCode}`,
      opener,
      `${name}, and a code block in the older release`,
    );

    // CI's format check rejects a fence that is open at the end of the file, and `mise run format` fixes it with this
    // Prettier: it closes the fence at the end of the file. The text is then a fixed point of the format check, no
    // fence is open, and every older release sits inside the closed fence.
    const formatted = runner.formatChangelogMarkdown(raw);
    assert.notEqual(formatted, raw, `${name}: prettier changes the raw text`);
    assert.equal(
      runner.formatChangelogMarkdown(formatted),
      formatted,
      `${name}: the formatted text passes the format check`,
    );
    refuses(formatted, formattedOpener, `${name}, after prettier`);
  }

  // Prettier formats the code in an `html`, `htm`, `mjml`, `vue`, `angular` or `handlebars` fence, and it joins the
  // lines of the code that it reads. A release heading that a broken fence swallows then stands in the middle of a
  // line, where no scan of line starts finds it. The real changelog shows it: Prettier moves `## [0.4.0]` onto the
  // line of the snippet. A template parser fails on the newest section of the real changelog and Prettier then leaves
  // the code alone, so `vue` and `angular` run on the older sections (0.3.0 and before), and `handlebars` runs on a
  // short changelog. The rule reads fences, not headings, so the reflow does not matter. Each case is [name,
  // changelog, the line that opens the fence, the same line after prettier].
  const olderReal = real.slice(real.indexOf("## [0.3.0]"));
  assert.ok(olderReal.startsWith("## [0.3.0]"), "the real changelog has 0.3.0");
  const reflowed = [];
  for (const info of ["html", "htm", "mjml"]) {
    reflowed.push([
      `${info} fence in the real changelog`,
      `${realHead}\n### Added\n\n- A hover card. Markup:\n\n\`\`\`${info}\n<span class="card">hover me</span>\n${real.slice(realHead.length + 1)}`,
      `\`\`\`${info}`,
      `\`\`\`${info}`,
    ]);
  }
  for (const info of ["vue", "angular"]) {
    reflowed.push([
      `${info} fence over the older sections of the real changelog`,
      `${realHead}\n### Added\n\n- Keys render as keycaps:\n\n~~~${info}\n<kbd>Ctrl</kbd>+<kbd>S</kbd>\n\`\`\`\n${olderReal}`,
      `~~~${info}`,
      `\`\`\`\`${info}`,
    ]);
  }
  reflowed.push([
    "handlebars fence in a short changelog",
    `${head}### Added\n\n- Keys render as keycaps:\n\n~~~handlebars\n<kbd>Ctrl</kbd>+<kbd>S</kbd>\n\`\`\`\n\n## [0.3.0] - 2026-10-01\n\n### Fixed\n\n- Fixed the diff view.\n\n## [0.2.0] - 2026-09-01\n\n### Added\n\n- Added the terminal.\n`,
    "~~~handlebars",
    "````handlebars",
  ]);
  for (const [name, raw, opener, formattedOpener] of reflowed) {
    const formatted = runner.formatChangelogMarkdown(raw);
    // No release heading stands at the start of a line after the fence opens, yet the headings are still in the text.
    assert.ok(
      !/^## \[/m.test(formatted.slice(formatted.indexOf(formattedOpener))) &&
        /## \[0\.3\.0\]/.test(formatted),
      `${name}: prettier moves the older headings off the start of a line`,
    );
    assert.equal(
      runner.formatChangelogMarkdown(formatted),
      formatted,
      `${name}: the formatted text passes the format check`,
    );
    refuses(formatted, formattedOpener, `${name}, after prettier`);
    refuses(raw, opener, `${name}, raw`);
  }

  // Whatever spelling a swallowed release heading has, and whatever the new entry shows, the fence is what is refused.
  const entries = [
    ["a new entry", entry],
    ["a new entry of the same version", "## [0.3.0] - 2026-11-11\n\n- New"],
    [
      "a new entry that shows the heading",
      "## [0.5.0] - 2026-11-11\n\n```md\n## [0.3.0] - 2025-09-15\n```",
    ],
  ];
  for (const spelling of [
    "## [0.3.0] - 2025-09-15",
    "## **0.3.0**",
    "## `v0.3.0`",
    "## [ 0.3.0 ]",
    "##  [0.3.0]",
    "## [0.3.0-rc.1]",
    "## V0.3.0",
    "\t## 0.3.0",
    "0.3.0\n-----",
  ]) {
    for (const [entryName, newEntry] of entries) {
      refuses(
        `${head}\`\`\`text\nDraft\n\n${spelling}\n\n- Previous\n`,
        "```text",
        `the heading ${JSON.stringify(spelling)} behind a draft fence, ${entryName}`,
        (text) => updateWith(newEntry, text),
      );
    }
  }

  // The costs: a fence is refused when it closes, when it holds nothing that looks like a release, and when the
  // draft is the draft of a first release.
  for (const [name, text, opener] of [
    [
      "a closed code block in the draft",
      `${head}Example:\n\n\`\`\`lua\nrequire("x").setup()\n\`\`\`\n${previous}`,
      "```lua",
    ],
    [
      "a closed tilde block in the draft",
      `${head}~~~sh\nnpm i\n~~~\n${previous}`,
      "~~~sh",
    ],
    [
      "a closed four-backtick block that holds a three-backtick line",
      `${head}\`\`\`\`md\n\`\`\`js\nx\n\`\`\`\n\`\`\`\`\n${previous}`,
      "````md",
    ],
    [
      "a fence indented by three spaces",
      `${head}   \`\`\`js\n   x\n   \`\`\`\n${previous}`,
      "   ```js",
    ],
    [
      "a first release whose draft holds a closed code block",
      `${head}\`\`\`markdown\n## Usage\nCall the API.\n\`\`\`\n`,
      "```markdown",
    ],
    [
      "a first release whose draft ends in an open Markdown example",
      `${head}Draft documentation for the first release:\n\n\`\`\`markdown\n## Usage\nCall the API.\n`,
      "```markdown",
    ],
  ]) {
    refuses(text, opener, name);
  }

  // Where the draft starts and ends: the first line after the Unreleased heading, and the last line of the text with
  // no line ending after it.
  refuses(
    "# Changelog\n\n## [Unreleased]\n```text\nDraft\n",
    "```text",
    "a fence on the first line after the Unreleased heading",
  );
  refuses(
    `${head}\`\`\`text`,
    "```text",
    "a fence on the last line of the text",
  );
  refuses(
    `${head}Draft\n\`\`\`text\n`,
    "```text",
    "a fence on the last line before the final line ending",
  );
  // The first fence is named, and a later one is not.
  refuses(
    `${head}\`\`\`a\nx\n\`\`\`\n\n\`\`\`b\ny\n\`\`\`\n${previous}`,
    "```a",
    "the first fence of two is named",
  );

  // Inputs that b477362 handled keep their output byte for byte. A fence is refused only inside the draft: the lines
  // from the first `# ` or `## ` line after the Unreleased heading on are never dropped, so a fence there, above the
  // heading, or in a text with no Unreleased heading changes nothing.
  const entryWithCode =
    '## [0.4.0] - 2026-06-15\n\n- Added x\n\n```lua\nrequire("x").setup()\n```';
  for (const [name, text, expected, newEntry = entry] of [
    [
      "an older release with a code block, after the draft",
      `${head}Draft${olderWithCode}`,
      "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n## [0.3.0] - 2025-09-15\n\n```js\nconsole.log(1);\n```\n\n- Previous\n",
    ],
    [
      "an older release whose code block follows its heading directly",
      `${head}Draft\n\n${release}\n\`\`\`js\nconsole.log(1);\n\`\`\`\n`,
      "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n## [0.3.0] - 2025-09-15\n\n```js\nconsole.log(1);\n```\n",
    ],
    [
      "a normal draft with subsections",
      `${head}### Added\n\n- Thing\n\n### Fixed\n\n- Other\n${previous}`,
      released,
    ],
    [
      "a draft with a line that has backticks and no fence",
      `${head}\`\`\`code\`\`\` is inline code.\n${previous}`,
      released,
    ],
    [
      "a new entry that holds a fence",
      `${head}Draft${previous}`,
      `# Changelog\n\n## [Unreleased]\n\n${entryWithCode}\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n`,
      entryWithCode,
    ],
    [
      "a code block above the Unreleased heading",
      `# Changelog\n\n\`\`\`text\nnote\n\`\`\`\n\n## [Unreleased]\n\nDraft${previous}`,
      `# Changelog\n\n\`\`\`text\nnote\n\`\`\`\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n`,
    ],
    [
      "a title and no Unreleased heading, with a fence in the text",
      `# Changelog\n\n\`\`\`md\n## Example\n\`\`\`${previous}`,
      `# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n\`\`\`md\n## Example\n\`\`\`\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n`,
    ],
    [
      "no title and no Unreleased heading, with a fence in the text",
      `\`\`\`md\n# Not a title\n\`\`\`${previous}`,
      `# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n\`\`\`md\n# Not a title\n\`\`\`\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n`,
    ],
    [
      "a text with nothing but the older release",
      previous.trimStart(),
      released,
    ],
    ["an empty draft", `${head}${previous.trimStart()}`, released],
  ]) {
    assert.equal(updateWith(newEntry, text), expected, name);
  }
  // A section that is not a release ends the draft of the update, and Communique reads past it, so it would show
  // twice (see `testUnreleasedDraftEnd`).
  const notesText = `${head}Draft\n\n## Upgrade notes\n\n- Read this\n${previous}`;
  assert.throws(
    () => withMissingFormatter(() => update(notesText)),
    {
      message: endMismatchRefusal(
        placeIn(notesText, "## Upgrade notes"),
        placeIn(notesText, release),
      ),
    },
    "a draft with no fence and a section that is not a release",
  );
  // A code line that is indented by four spaces is not a fence. It is an indented code block, and the update refuses
  // it as one (see `testUnreleasedDraftStructure`).
  assert.throws(
    () =>
      withMissingFormatter(() =>
        update(`${head}Example:\n\n    \`\`\`js\n    x\n${previous}`),
      ),
    { message: nodeRefusal(7, "    ```js", "code_block (indented)") },
    "an indented code block is not a fence",
  );
  // A first release has a draft with no fence and no older release below it. The draft is the rest of the text.
  assert.equal(
    update(`${head}### Added\n\n- Added x\n`),
    entryOnly,
    "a first release whose draft has no fence",
  );
  // An empty draft: an older release follows the Unreleased heading directly, or the text ends at the heading.
  assert.equal(
    update(`# Changelog\n\n## [Unreleased]\n${release}\n\n- Previous\n`),
    released,
    "an older release directly under the Unreleased heading",
  );
  assert.equal(
    update("# Changelog\n\n## [Unreleased]"),
    entryOnly,
    "a text that ends at the Unreleased heading",
  );

  // The real changelog keeps every release in all three endings, and the draft is replaced by the entry.
  const realUpdated = runner.formatChangelogMarkdown(
    real.replace(realHead, `${realHead}\n${entry}\n`),
  );
  for (const [name, ending] of [
    ["LF", "\n"],
    ["CRLF", "\r\n"],
    ["CR", "\r"],
  ]) {
    assert.equal(
      update(real.replace(/\n/g, ending)),
      realUpdated,
      `the real changelog, ${name} endings`,
    );
  }
  assert.ok(
    realUpdated.includes("## [0.1.0]") && realUpdated.includes("## [0.4.0]"),
    "the real changelog keeps its releases",
  );
}

/**
 * What the update wrote before it read the draft with a parser, for a text that it handled without loss: the draft is
 * everything after the Unreleased heading up to the first `# ` or `## ` line outside a fence, and the entry replaces it.
 * `written` is the text before the formatter runs (an identity formatter gives it), and `rest` the lines that stay.
 */
function textThatMainWrites(text, entry) {
  const lines = text.split(/\r\n|\r|\n/);
  const unreleased = runner.findLineOutsideFences(lines, 0, (line) =>
    /^#{2,3} \[?Unreleased\]?[ \t]*$/.test(line),
  );
  const next = runner.findLineOutsideFences(lines, unreleased + 1, (line) =>
    /^##? /.test(line),
  );
  const rest = next === -1 ? "" : lines.slice(next).join("\n");
  const sections = [
    lines
      .slice(0, unreleased + 1)
      .join("\n")
      .trimEnd(),
    entry.trim(),
  ];
  if (rest.trim() !== "") {
    sections.push(rest.trim());
  }
  return { written: `${sections.join("\n\n")}\n`, rest };
}

/**
 * The error of `updateContent` for a draft that holds a node that it does not read (see `assertDraftIsPlain`). `kind`
 * is the commonmark.js node type.
 */
function nodeRefusal(lineNumber, line, kind) {
  return (
    `The Unreleased draft has a node that the update does not read: ${kind}. Line ${lineNumber} starts it: ${JSON.stringify(line.slice(0, 80))}. ` +
    "The update drops the draft, so it reads only paragraphs, lists and level 3 headings there. " +
    "Move it out of the Unreleased draft."
  );
}

/** The error of `updateContent` for a line that no paragraph or heading holds (a link definition). */
function uncoveredRefusal(lineNumber, line) {
  return (
    `The Unreleased draft has a line that no paragraph or heading holds. Line ${lineNumber}: ${JSON.stringify(line.slice(0, 80))}. ` +
    "A link reference definition is one. The update drops the draft, so it refuses a line that it cannot read. " +
    "Move it out of the Unreleased draft."
  );
}

/**
 * A place in a text for the two refusals below: `{ number, line }`, with the line numbered from 1, or `null` for the
 * end of the text (or no line).
 */
function placeIn(text, line) {
  const number = lineNumberOf(text, line);
  assert.ok(number > 0, `the text holds ${JSON.stringify(line)}`);
  return { number, line };
}

/**
 * The error of `updateContent` when the update and Communique end the Unreleased draft at different lines. `update` is
 * the place where the update ends the draft and `communique` the place where Communique ends it (see `placeIn`), or
 * null for the end of the text. Communique ends it later than the update when its line is below the update's line, and
 * `communiqueIsLater` says so when the two have the same number (a bare CR line break makes that happen).
 */
function endMismatchRefusal(
  update,
  communique,
  communiqueIsLater = communique === null ||
    (update !== null && communique.number > update.number),
) {
  const describe = (place) =>
    place === null
      ? "the end of the text"
      : `line ${place.number}: ${JSON.stringify(place.line.slice(0, 80))}`;
  return (
    "The update and Communique end the Unreleased draft in different places. " +
    `The update ends it at ${describe(update)}. Communique ends it at ${describe(communique)}. ` +
    (communiqueIsLater
      ? "Communique reads the lines in between as draft too and folds them into the new entry, and the update keeps them, so they would show twice. "
      : "Communique never reads the lines in between, and the update would drop them. ") +
    "Communique ends a draft only at a `## ` heading with a version, such as `## [0.4.1]`. " +
    "Write the heading that ends the draft that way, or move the lines in between out of the Unreleased draft."
  );
}

/**
 * The error of `updateContent` when the update and Communique find the Unreleased heading at different lines. Each
 * place is `{ number, line }` or null for no line (see `placeIn`).
 */
function anchorMismatchRefusal(update, communique) {
  const describe = (place) =>
    place === null
      ? "no line"
      : `line ${place.number}: ${JSON.stringify(place.line.slice(0, 80))}`;
  return (
    "The update and Communique find the Unreleased heading in different places. " +
    `The update finds it at ${describe(update)}. Communique finds it at ${describe(communique)}. ` +
    "The update would drop a draft that Communique never read, keep one that Communique folds into the new entry, or add a second Unreleased heading. " +
    "Communique reads `## [Unreleased]` and `## Unreleased` after it trims the line, and it reads `## [Unreleased](...)`. " +
    "Write the heading as `## [Unreleased]` at the start of a line, once."
  );
}

/** The error of `updateContent` for a draft under an H3 heading, which Communique does not read. */
function levelRefusal(level, lineNumber, line) {
  return (
    `The Unreleased draft sits under a level ${level} heading. Line ${lineNumber} starts it: ${JSON.stringify(line.slice(0, 80))}. ` +
    "Communique reads a draft only under `## [Unreleased]` or `## Unreleased`, so the update would drop text that nobody reconciled into the new entry. " +
    "Move the draft under `## [Unreleased]`, or remove it."
  );
}

/** The error of `updateContent` when the formatter changes the headings of the new entry and the older releases. */
function changedRefusal(expected, found) {
  return (
    "The update would change the older releases. After the formatter runs, the headings of the new entry and the older releases are not the headings that were there: " +
    `expected ${JSON.stringify(expected)} but found ${JSON.stringify(found)}. ` +
    "The new entry or the older releases hold Markdown that the formatter rewrites, such as a code fence that never closes, so the update refuses to write it."
  );
}

/** The line of a text that equals `line`, numbered from 1, or 0. */
function lineNumberOf(text, line) {
  return text.split(/\r\n|\r|\n/).indexOf(line) + 1;
}

/**
 * Runs `check` on every case and fails once, with the name of each case that failed, so one run shows every broken
 * case. A case is an object with a `name`.
 */
function checkCases(cases, check) {
  const failures = [];
  for (const testCase of cases) {
    try {
      check(testCase);
    } catch (error) {
      failures.push(
        `${testCase.name}: ${String(error.message).split("\n")[0]}`,
      );
    }
  }
  assert.deepEqual(
    failures,
    [],
    `${failures.length} of ${cases.length} cases fail`,
  );
}

/** The `level text` of each top-level heading of a text, as commonmark.js reads it. It is the judge of the tests below. */
function topLevelHeadingsOf(text) {
  const headings = [];
  for (
    let block = new commonmark.Parser().parse(text).firstChild;
    block;
    block = block.next
  ) {
    if (block.type !== "heading") {
      continue;
    }
    let literal = "";
    for (let child = block.firstChild; child; child = child.next) {
      literal += child.literal ?? "";
    }
    headings.push(`${block.level} ${literal.replace(/\s+/g, " ").trim()}`);
  }
  return headings;
}

/**
 * Runs `fn` with a formatter that is the shell script `body`. The runner calls it with the text on its standard input,
 * as it calls prettier.
 */
function withFormatterScript(body, fn) {
  const directory = mkdtempSync(join(tmpdir(), "stub-formatter-"));
  const formatter = join(directory, "format.sh");
  writeFileSync(formatter, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  const previousFormatter = process.env.PRETTIER_BIN;
  process.env.PRETTIER_BIN = formatter;
  try {
    return fn();
  } finally {
    if (previousFormatter === undefined) {
      delete process.env.PRETTIER_BIN;
    } else {
      process.env.PRETTIER_BIN = previousFormatter;
    }
    rmSync(directory, { recursive: true, force: true });
  }
}

/**
 * A frozen copy of the Unreleased draft of every state of the real CHANGELOG.md that has an Unreleased heading, from
 * the first commit to the 0.4.0 release (`fixtures/changelog-drafts.json`). Each state is [commit, text]. The text is
 * the file as it was, and the test never reads the live CHANGELOG.md. `rest` is the part of the file after the draft:
 * the string itself, or "older" for the sections of the frozen released changelog from 0.3.0 on, or "released" for all
 * of it.
 */
function readHistoricalChangelogs(releasedSections) {
  const older = releasedSections.slice(releasedSections.indexOf("## [0.3.0]"));
  return JSON.parse(
    readFileSync(join(__dirname, "fixtures", "changelog-drafts.json"), "utf8"),
  ).map(({ commit, head, draft, rest }) => {
    const tail =
      rest === "older" ? older : rest === "released" ? releasedSections : rest;
    return [commit, `${head}\n${draft}\n${tail}`];
  });
}

/**
 * The structure of the Unreleased draft. `updateContent` reads the changelog with commonmark.js. It drops a draft that
 * holds only paragraphs, lists and H3 headings, it refuses any other node before it formats, and it refuses a formatter
 * that changes the headings of the older releases. A release heading that a reader of lines misses (an H3 or deeper
 * heading is the exception) is a section heading to the parser. Each case that main loses is here, and it fails on main.
 */
async function testUnreleasedDraftStructure() {
  const entry = "## [0.4.0] - 2026-06-15\n\n* Added x";
  const update = (content, newEntry = entry) =>
    new runner.UnreleasedAwareChangelog({
      changelogEntry: newEntry,
    }).updateContent(content);
  const head = "# Changelog\n\n## [Unreleased]\n\n";
  const release = "## [0.3.0] - 2025-09-15";
  const previous = `\n\n${release}\n\n- Previous\n`;
  const released =
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n";
  const entryOnly =
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n";
  const releasedSections = readFileSync(
    join(__dirname, "fixtures", "changelog-released.md"),
    "utf8",
  );
  const realHead = "# Changelog\n\n## [Unreleased]\n";
  // A run with the identity formatter must give the text that the update wrote before this check.
  const mainText = (text, newEntry = entry) =>
    textThatMainWrites(text, newEntry).written;

  // 1. Refusals, before the formatter runs, raw and after the real prettier. The error names the line and the node.
  // Each case is { name, draft, error, line, formattedLine }: `error` builds the error from the line number and the
  // line that starts the node, and `formattedLine` is that line after prettier when prettier changes it.
  const node = (kind) => (number, line) => nodeRefusal(number, line, kind);
  const refusedCases = [
    ...["####", "#####", "######"].map((marks) => ({
      name: `an H${marks.length} release heading under Unreleased`,
      draft: `${marks} [0.3.0] - 2025-09-15\n\n- Older`,
      line: `${marks} [0.3.0] - 2025-09-15`,
      error: node(`heading (level ${marks.length})`),
    })),
    {
      name: "an H4 heading after a subsection",
      draft: "### Added\n\n- Thing\n\n#### Detail\n\n- Older",
      line: "#### Detail",
      error: node("heading (level 4)"),
    },
    {
      name: "a div that holds a heading line and a fence line",
      draft: "<div>\n## Notes\n```js\n</div>",
      line: "<div>",
      error: node("html_block"),
    },
    {
      name: "details that hold a heading line and a fence line",
      draft: "<details>\n# Notes\n```\n</details>",
      line: "<details>",
      error: node("html_block"),
    },
    {
      name: "a comment that never closes",
      draft: "<!--\n# x",
      line: "<!--",
      error: node("html_block"),
    },
    {
      name: "a pre element",
      draft: "<pre>\n## x\n",
      line: "<pre>",
      error: node("html_block"),
    },
    {
      name: "an H2 heading in a list item",
      draft: "- ## [0.3.0] - 2025-09-15\n\n  - Older",
      line: "- ## [0.3.0] - 2025-09-15",
      error: node("heading (level 2)"),
    },
    {
      name: "a setext heading in a list item",
      draft: "- Draft\n\n  0.3.0\n  -----\n\n  - Older",
      line: "  0.3.0",
      formattedLine: "  ## 0.3.0",
      error: node("heading (level 2)"),
    },
    {
      name: "an H1 heading in a list item",
      draft: "1. # Title\n\n   - Older",
      line: "1. # Title",
      error: node("heading (level 1)"),
    },
    {
      name: "an H2 heading in a block quote",
      draft: "> ## [0.3.0] - 2025-09-15\n>\n> - Older",
      line: "> ## [0.3.0] - 2025-09-15",
      error: node("block_quote"),
    },
    {
      name: "a block quote",
      draft: "> A note.",
      line: "> A note.",
      error: node("block_quote"),
    },
    ...[
      ["***", "---"],
      ["___", "---"],
      ["- - -", "---"],
      ["---", "---"],
    ].map(([rule, formatted]) => ({
      name: `a thematic break ${rule}`,
      draft: `Draft text.\n\n${rule}\n\n- Older`,
      line: rule,
      formattedLine: formatted,
      error: node("thematic_break"),
    })),
    {
      name: "a link definition",
      draft: "Draft text.\n\n[docs]: https://example.com/docs\n\n- Older",
      line: "[docs]: https://example.com/docs",
      error: uncoveredRefusal,
    },
    {
      name: "a link definition right before the next release",
      draft: "Draft text.\n\n[docs]: https://example.com/docs",
      line: "[docs]: https://example.com/docs",
      error: uncoveredRefusal,
      directly: true,
    },
    {
      name: "a link definition after an empty marker",
      draft: "-\n  [x]: https://e.x",
      line: "  [x]: https://e.x",
      formattedLine: "- [x]: https://e.x",
      error: uncoveredRefusal,
    },
    {
      name: "a link definition in a list item",
      draft: "- [docs]: https://example.com/docs",
      line: "- [docs]: https://example.com/docs",
      error: uncoveredRefusal,
    },
    {
      name: "an indented code block",
      draft: 'Example:\n\n    require("x").setup()\n\n- Older',
      line: '    require("x").setup()',
      error: node("code_block (indented)"),
    },
    {
      name: "a fence in a list item",
      draft: "- Example:\n\n  ```lua\n  x()\n  ```",
      line: "  ```lua",
      error: refusal,
    },
  ];
  const refusedTexts = refusedCases.map(
    (testCase) =>
      `${head}${testCase.draft}${testCase.directly ? `\n${previous.trimStart()}` : previous}`,
  );
  const refusedFormatted = formatDocuments(refusedTexts);
  checkCases(refusedCases, (testCase) => {
    const index = refusedCases.indexOf(testCase);
    for (const [label, text, line] of [
      ["raw", refusedTexts[index], testCase.line],
      [
        "after prettier",
        refusedFormatted[index],
        testCase.formattedLine ?? testCase.line,
      ],
    ]) {
      const number = lineNumberOf(text, line);
      assert.ok(number > 0, `${label}: the text holds ${JSON.stringify(line)}`);
      assert.throws(
        () => withMissingFormatter(() => update(text)),
        { message: testCase.error(number, line) },
        label,
      );
    }
  });

  // The first and the last line of the draft, and a draft that runs to the end of the text, are read as well.
  for (const [name, text, number, line] of [
    [
      "a link definition on the first line",
      "# Changelog\n\n## [Unreleased]\n[docs]: https://example.com/x\n\n## [0.3.0] - 2025-09-15\n",
      4,
      "[docs]: https://example.com/x",
    ],
    [
      "a link definition at the end of the text",
      `${head}[docs]: https://example.com/x`,
      5,
      "[docs]: https://example.com/x",
    ],
    [
      "a link definition on the last line, after a final line ending",
      `${head}[docs]: https://example.com/x\n`,
      5,
      "[docs]: https://example.com/x",
    ],
  ]) {
    assert.throws(
      () => withMissingFormatter(() => update(text)),
      { message: uncoveredRefusal(number, line) },
      name,
    );
  }

  // 2. Release headings that a reader of lines misses stay in the changelog. The parser reads them as headings, so the
  // draft ends before them. Main read a heading only at the start of a line, with one space after its marks.
  const keptCases = [
    [
      "an H2 heading that is indented by one space",
      "Draft text.\n\n ## [0.3.0] - 2025-09-15",
    ],
    [
      "an H2 heading that is indented by three spaces",
      "Draft text.\n\n   ## [0.3.0] - 2025-09-15",
    ],
    // One space of indent ends the list item before it. Three spaces would put the heading inside the item.
    [
      "an H2 heading that is indented by one space, after a list",
      "- Draft\n\n ## [0.3.0] - 2025-09-15",
    ],
    [
      "an H2 heading with two spaces after the marks",
      "Draft text.\n\n##  [0.3.0] - 2025-09-15",
    ],
    [
      "an H2 heading with runs of blanks in its text",
      "Draft text.\n\n## [0.3.0]   -   2025-09-15   ",
    ],
    [
      "an H2 heading that has a closing sequence",
      "Draft text.\n\n## [0.3.0] - 2025-09-15 ##",
    ],
  ].map(([name, draft]) => ({
    name,
    raw: `${head}${draft}\n\n- Previous\n`,
  }));
  const keptFormatted = formatDocuments(keptCases.map(({ raw }) => raw));
  checkCases(keptCases, (testCase) => {
    const formatted = keptFormatted[keptCases.indexOf(testCase)];
    assert.equal(update(testCase.raw), released, "raw");
    assert.equal(update(formatted), released, "after prettier");
  });
  // 2b. Communique ends its draft only at a `## <version>` line, so it reads the text below an empty or a setext
  // heading as draft too and folds it into the new entry. The update ends its draft at that heading and keeps the text,
  // so it would show twice, and the update refuses them. Each case is { name, draft, line, formattedLine }:
  // `formattedLine` is the heading line after prettier. Prettier turns a setext heading into an ATX heading, which is
  // not a version heading either (see `testUnreleasedDraftEnd` for the ones that are).
  const endCases = [
    ["an empty H1", "Draft text.\n\n#\n\n- Rest of the draft", "#", "#"],
    ["an empty H2", "Draft text.\n\n##\n\n- Rest of the draft", "##", "##"],
    [
      "an H2 with blanks only",
      "Draft text.\n\n##   \n\n- Rest of the draft",
      "##   ",
      "##",
    ],
    [
      "an H2 with a closing sequence only",
      "Draft text.\n\n## ##\n\n- Rest of the draft",
      "## ##",
      "##",
    ],
    [
      "an empty H2 right after the anchor",
      "##\n\n- Rest of the draft",
      "##",
      "##",
    ],
    [
      "an H2 with a character reference that is a blank",
      "Draft text.\n\n## &nbsp;\n\n- Rest of the draft",
      "## &nbsp;",
      "## &nbsp;",
    ],
    [
      "a setext H1",
      "Draft text.\n\nTitle\n=====\n\n- Rest of the draft",
      "Title",
      "# Title",
    ],
    [
      "a setext H2",
      "Draft text.\n\nTitle\n-----\n\n- Rest of the draft",
      "Title",
      "## Title",
    ],
    [
      "a setext H2 of two lines",
      "Draft text.\n\nLine one\nline two\n-----\n\n- Rest of the draft",
      "Line one",
      // Prettier does not read a setext heading of two lines. It writes a paragraph and a thematic break.
      "---",
      (number, line) => nodeRefusal(number, line, "thematic_break"),
    ],
  ].map(([name, draft, line, formattedLine, formattedError]) => ({
    name,
    text: `${head}${draft}${previous}`,
    line,
    formattedLine,
    formattedError,
  }));
  const endFormatted = formatDocuments(endCases.map(({ text }) => text));
  // The update ends the draft at `line` and Communique at the older release.
  const endRefused = (text, line) =>
    endMismatchRefusal(placeIn(text, line), placeIn(text, release));
  checkCases(endCases, (testCase) => {
    assert.throws(
      () => withMissingFormatter(() => update(testCase.text)),
      { message: endRefused(testCase.text, testCase.line) },
      "raw",
    );
    const formatted = endFormatted[endCases.indexOf(testCase)];
    const formattedNumber = lineNumberOf(formatted, testCase.formattedLine);
    assert.ok(formattedNumber > 0, "the formatted text holds the heading");
    assert.throws(
      () => withMissingFormatter(() => update(formatted)),
      {
        message:
          testCase.formattedError?.(formattedNumber, testCase.formattedLine) ??
          endRefused(formatted, testCase.formattedLine),
      },
      "after prettier",
    );
  });

  // 2c. Communique trims a line with Rust's `trim` and ends its draft at a trimmed `## <version>` line. CommonMark keeps
  // most of those blanks as text, so a draft line that starts with one of them, then `## ` and a version, is a paragraph
  // to the update, and Communique never reads the lines below it. The update ends its draft at the next heading, so it
  // refuses such a line. The blanks are the ones that Rust trims, except the space and the tab, which CommonMark reads
  // as indent: VT, FF, NEL, no-break space, U+1680, U+2000 to U+200A, the line and paragraph separators, U+202F, U+205F
  // and U+3000.
  const communiqueBlanks = [
    "\u000b",
    "\u000c",
    "\u0085",
    "\u00a0",
    "\u1680",
    ...Array.from({ length: 11 }, (_, k) => String.fromCharCode(0x2000 + k)),
    "\u2028",
    "\u2029",
    "\u202f",
    "\u205f",
    "\u3000",
  ];
  const blankCases = [
    ...communiqueBlanks.map((blank) => ({
      name: `U+${blank.codePointAt(0).toString(16).padStart(4, "0")} before the heading`,
      line: `${blank}## [0.2.0] - 2026-02-02 MK2`,
      draft: `- MK1\n\n${blank}## [0.2.0] - 2026-02-02 MK2\n\n- MK3`,
      // Prettier removes a form feed, so only the raw text holds it.
      rawOnly: blank === "\u000c",
    })),
    {
      name: "a no-break space before an H2 right after the anchor",
      line: "\u00a0## [0.2.0] - 2026-02-02 MK2",
      draft: "\u00a0## [0.2.0] - 2026-02-02 MK2\n\n- MK3",
    },
    {
      name: "a line of the draft paragraph with four spaces of indent",
      line: "    ## [0.2.0] - 2026-02-02 MK2",
      draft: "Some text\n    ## [0.2.0] - 2026-02-02 MK2\n\n- MK3",
      rawOnly: true,
    },
    {
      name: "a line of a list item paragraph with six spaces of indent",
      line: "      ## [0.2.0] - 2026-02-02 MK2",
      draft: "- item\n      ## [0.2.0] - 2026-02-02 MK2\n\n- MK3",
      rawOnly: true,
    },
    {
      name: "a line of the draft paragraph with a tab of indent",
      line: "\t## [0.2.0] - 2026-02-02 MK2",
      draft: "Some text\n\t## [0.2.0] - 2026-02-02 MK2\n\n- MK3",
      rawOnly: true,
    },
  ];
  const blankTexts = blankCases.map(
    ({ draft }) => `${head}${draft}${previous}`,
  );
  const blankFormatted = formatDocuments(blankTexts);
  checkCases(blankCases, (testCase) => {
    const index = blankCases.indexOf(testCase);
    const variants = [["raw", blankTexts[index]]];
    // Prettier joins a lazy line into its paragraph and removes a form feed, so the line no longer starts with `## `.
    if (!testCase.rawOnly) {
      variants.push(["after prettier", blankFormatted[index]]);
    }
    for (const [label, text] of variants) {
      const number = lineNumberOf(text, testCase.line);
      assert.ok(number > 0, `${label}: the text holds the line`);
      // Communique ends its draft at the line, and the update ends it at the older release.
      assert.throws(
        () => withMissingFormatter(() => update(text)),
        {
          message: endMismatchRefusal(placeIn(text, release), {
            number,
            line: testCase.line,
          }),
        },
        label,
      );
    }
  });
  // The first and the last line of the draft are read as well.
  const nbspHeading = "\u00a0## [0.2.0] - 2026-02-02 MK2";
  for (const [name, text, number, older] of [
    [
      "the first line of the draft",
      `# Changelog\n\n## [Unreleased]\n${nbspHeading}\n\n- MK3${previous}`,
      4,
      release,
    ],
    [
      "the last line of the draft",
      `${head}- MK1\n${nbspHeading}\n## [0.1.0] - 2026-01-01\n\n- MK9\n`,
      6,
      "## [0.1.0] - 2026-01-01",
    ],
  ]) {
    assert.throws(
      () => withMissingFormatter(() => update(text)),
      {
        message: endMismatchRefusal(placeIn(text, older), {
          number,
          line: nbspHeading,
        }),
      },
      name,
    );
  }
  // These lines do not end the draft of Communique, so it reads them as text, and the text of main is the text that the
  // update writes: a character that Rust does not trim, a blank inside the line, a deeper heading, no space after the
  // marks, and an H2 with no version.
  const readLines = [
    [
      "a zero width space before the marks",
      "\u200b## [0.2.0] - 2026-02-02 MK2",
    ],
    ["a byte order mark before the marks", "\ufeff## [0.2.0] - 2026-02-02 MK2"],
    [
      "a no-break space inside the line",
      "text\u00a0## [0.2.0] - 2026-02-02 MK2",
    ],
    [
      "a no-break space after the marks",
      "\u00a0##\u00a0[0.2.0] - 2026-02-02 MK2",
    ],
    ["a no-break space before an H3", "\u00a0### Added"],
    ["a no-break space before an H2 with no version", "\u00a0## Notes"],
    ["no space after the marks", "\u00a0##[0.2.0] - 2026-02-02 MK2"],
    ["a tab after the marks", "\u00a0##\t[0.2.0] - 2026-02-02 MK2"],
  ].map(([name, line]) => ({ name, line }));
  checkCases(readLines, ({ line }) => {
    const text = `${head}- MK1\n\n${line}\n\n- MK3${previous}`;
    withIdentityFormatter(() =>
      assert.equal(update(text), mainText(text), "the text of main"),
    );
  });

  // 3. A setext heading is a heading. After a list item, prettier moves it into the item and writes a thematic
  // break, so the update refuses the text before the formatter (when it is already formatted) or after it (when it is
  // raw). Nothing is written, and the older release is not lost.
  const setext = "- Draft\n\n0.3.0\n-----\n\n- Previous\n";
  assert.throws(
    () => withMissingFormatter(() => update(`${head}${setext}`)),
    // Communique reads the draft to the end of the text.
    { message: endMismatchRefusal({ number: 7, line: "0.3.0" }, null) },
    "a raw setext heading that ends the draft",
  );
  // A raw setext older release further down is kept text. Prettier moves it into the list item above it, so the
  // update refuses the formatted text.
  assert.throws(
    () => update(`${head}- Draft${previous}\n0.2.0\n-----\n\n- Older\n`),
    { message: changedRefusal("2 [0.4.0] - 2026-06-15", "2 [Unreleased]") },
    "a raw setext older release below the list of an older release",
  );
  const formattedSetext = runner.formatChangelogMarkdown(`${head}${setext}`);
  assert.equal(
    formattedSetext,
    `${head}- Draft\n\n  0.3.0\n\n---\n\n- Previous\n`,
    "prettier moves the setext heading into the list item",
  );
  assert.throws(
    () => withMissingFormatter(() => update(formattedSetext)),
    { message: nodeRefusal(9, "---", "thematic_break") },
    "the formatted text holds a thematic break and no release heading",
  );
  for (const [underline, atx] of [
    ["=====", "# 0.3.0"],
    ["-----", "## 0.3.0"],
  ]) {
    // Not after a list item: prettier writes an ATX heading.
    const text = `${head}Draft text.\n\n0.3.0\n${underline}\n\n- Previous\n`;
    const formatted = runner.formatChangelogMarkdown(text);
    assert.ok(
      formatted.includes(`${atx}\n\n- Previous`),
      "prettier writes ATX",
    );
    if (atx.startsWith("## ")) {
      // An H2 with a version ends the draft of Communique too, and the text is kept as written by prettier.
      assert.equal(
        update(formatted),
        `${entryOnly}\n${formatted.slice(formatted.indexOf("#", head.length))}`.replace(
          "\n\n\n",
          "\n\n",
        ),
        `the setext ${underline} release after prettier`,
      );
    } else {
      // An H1 does not end the draft of Communique, which reads the text below it as draft.
      assert.throws(
        () => withMissingFormatter(() => update(formatted)),
        { message: endMismatchRefusal(placeIn(formatted, atx), null) },
        `the setext ${underline} release after prettier`,
      );
    }
  }

  // 4. The contract: an H3 heading directly under `## [Unreleased]` is a subsection of the draft, whatever it says,
  // so it is dropped with the draft. The next H2 heading ends the draft.
  assert.equal(
    update(
      `${head}### [0.3.0] - 2025-09-15\n\n- Dropped\n\n## [0.2.0] - 2025-06-18\n\n- Older\n`,
    ),
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n## [0.2.0] - 2025-06-18\n\n- Older\n",
    "an H3 release heading under Unreleased is part of the draft",
  );
  // The draft of an H3 anchor ends at the next heading of level 3 or less, so the H3 releases stay. Communique reads no
  // draft under an H3 anchor, so a non-empty one is refused (see `testUnreleasedAnchor`).
  assert.equal(
    update(
      "# Changelog\n\n### [Unreleased]\n\n### [0.3.0] - 2025-09-15\n\n- Previous\n\n### [0.2.0] - 2025-06-18\n\n- Older\n",
    ),
    "# Changelog\n\n### [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n### [0.3.0] - 2025-09-15\n\n- Previous\n\n### [0.2.0] - 2025-06-18\n\n- Older\n",
    "an H3 anchor with no draft keeps every H3 release",
  );

  // 5. What stays out of the draft cannot hide a release. A fence that is indented by four or more spaces is code, and
  // a fence in a block quote or a list item ends with its container, so a release heading after it is a heading. The
  // constructs stand in an older release here. Main and the update write the same text, and every release stays a
  // top-level heading.
  const hiding = [
    ["a fence indented by four spaces", "    ```js\n    x\n"],
    ["a fence indented by five spaces", "     ```js\n     x\n"],
    ["a fence indented by a tab", "\t```js\n\tx\n"],
    ["a fence in a block quote", "> ```js\n> x\n"],
    ["a fence in a block quote without a closing blank line", "> ```js\n> x"],
    ["a fence in a list item", "- Example:\n\n  ```js\n  x\n"],
    ["a fence in a list item that the next release ends", "- ```js\n  x"],
    [
      "a closed fence that holds a release heading",
      "```md\n## [0.2.0] - 2025-06-18\n```\n",
    ],
  ].map(([name, code]) => ({ name, code }));
  checkCases(hiding, ({ code }) => {
    const text = `${head}- Draft\n\n${release}\n\n${code}\n## [0.2.0] - 2025-06-18\n\n- Older\n`;
    assert.equal(
      withIdentityFormatter(() => update(text)),
      mainText(text),
      "main's text",
    );
    assert.deepEqual(
      topLevelHeadingsOf(update(text)),
      [
        "1 Changelog",
        "2 [Unreleased]",
        "2 [0.4.0] - 2026-06-15",
        "2 [0.3.0] - 2025-09-15",
        "2 [0.2.0] - 2025-06-18",
      ],
      "every release stays a top-level heading",
    );
  });
  // The same constructs in the draft are refused: it is code, a quote or an open fence, and the update does not read them.
  for (const [name, code, error] of [
    [
      "a fence indented by four spaces",
      "    ```js\n    x",
      nodeRefusal(5, "    ```js", "code_block (indented)"),
    ],
    [
      "a fence in a block quote",
      "> ```js\n> x",
      nodeRefusal(5, "> ```js", "block_quote"),
    ],
  ].map(([name, code, message]) => [name, code, message])) {
    assert.throws(
      () => withMissingFormatter(() => update(`${head}${code}${previous}`)),
      { message: error },
      name,
    );
  }

  // 6. Drafts that the update reads give the text that main wrote, byte for byte: paragraphs, nested lists, H3
  // subsections, inline code, HTML and links, a wrapped line that starts with `#123`, and an empty draft.
  const ordinary = [
    [
      "the draft of #252",
      "### Bug Fixes\n\n- Work around a Neovim core bug (< 0.12.2) that fragmented large pastes. ([#161](https://github.com/coder/claudecode.nvim/issues/161))\n",
    ],
    ["a flat list", "- One\n- Two\n- Three\n"],
    [
      "a nested list",
      "- One\n  - Two\n    - Three\n- Four\n\n1. Five\n   - Six\n2. Seven\n",
    ],
    [
      "subsections",
      "### Added\n\n- Thing\n\n### Fixed\n\n- Other\n\n### Changed\n\n- Third\n",
    ],
    [
      "a paragraph and a list",
      "Draft notes.\n\nMore notes\nwrapped here.\n\n- Item\n",
    ],
    [
      "inline code, HTML and links",
      "- Use `vim.paste` and <kbd>Ctrl</kbd>+<kbd>S</kbd> with [docs](https://example.com/a_b) and ![img](x.png)\n- <b>Bold</b> text and a bare https://example.com/x link\n",
    ],
    ["an empty list item", "- One\n-\n- Three\n"],
    ["an empty item that holds an empty item", "- One\n- -\n"],
    ["an empty item with a parenthesis marker", "1) One\n2)\n3) Three\n"],
    ["an empty item with blanks after the marker", "- One\n-   \n- Three\n"],
    ["an empty ordered list item", "1. One\n2.\n3. Three\n"],
    ["empty lists", "-\n\n1.\n\n*\n"],
    ["a nested empty list item", "- a\n\n  -\n"],
    ["a marker with its text on the next line", "-\n  text\n"],
    [
      "emphasis, strong text and a hard break",
      "- **Bold** and *emphasis* and _more_\\\n  after a hard break\n- Line one  \n  line two\n",
    ],
    [
      "a wrapped line that starts with an issue number",
      "- Fixed the crash\n#123 and the hang\n- Other\n",
    ],
    ["a loose list", "- One\n\n- Two\n\n  More about two.\n"],
    ["an H3 inside a list item", "- ### Heading in an item\n\n  - Item\n"],
    ["an empty draft", ""],
  ].map(([name, draft]) => ({ name, draft }));
  const ordinaryTexts = ordinary.map(
    (testCase) => `${head}${testCase.draft}${previous}`,
  );
  const ordinaryFormatted = formatDocuments(ordinaryTexts);
  checkCases(ordinary, (testCase) => {
    const index = ordinary.indexOf(testCase);
    withIdentityFormatter(() => {
      for (const [label, text] of [
        ["raw", ordinaryTexts[index]],
        ["after prettier", ordinaryFormatted[index]],
      ]) {
        assert.equal(update(text), mainText(text), label);
        assert.equal(
          update(text.replace(/\n/g, "\r\n")),
          mainText(text),
          `${label}, "\\r\\n" endings`,
        );
        // Communique ends a line at LF only, so it reads no draft in a text with bare CR line breaks. The update would
        // drop a draft that Communique never read, and refuses it. There is nothing to drop in an empty draft.
        const bareCr = text.replace(/\n/g, "\r");
        if (testCase.draft === "") {
          assert.equal(
            update(bareCr),
            mainText(text),
            `${label}, "\\r" endings`,
          );
        } else {
          assert.throws(
            () => withMissingFormatter(() => update(bareCr)),
            {
              message: anchorMismatchRefusal(
                { number: 3, line: "## [Unreleased]" },
                null,
              ),
            },
            `${label}, "\\r" endings`,
          );
        }
      }
    });
  });
  assert.equal(
    update(`${head}### Added\n\n- Added x\n`),
    entryOnly,
    "a draft at the end of the text",
  );
  assert.equal(
    update("# Changelog\n\n## [Unreleased]\n### Added\n\n- Added x"),
    entryOnly,
    "a draft right after the heading",
  );

  // 7. All 20 states of the real changelog that have an Unreleased heading are read, and each gives main's text. The
  // draft of the 0.4.0 release (the last state with a draft) gives the released changelog with the real entry.
  const history = readHistoricalChangelogs(releasedSections);
  assert.equal(history.length, 20, "the states of the real changelog");
  withIdentityFormatter(() => {
    for (const [commit, text] of history) {
      const lines = text.split("\n");
      const unreleased = lines.findIndex((line) => line === "## [Unreleased]");
      const next = lines.findIndex(
        (line, i) => i > unreleased && /^##? /.test(line),
      );
      const rest = next === -1 ? "" : lines.slice(next).join("\n");
      const expected = `${[
        lines
          .slice(0, unreleased + 1)
          .join("\n")
          .trimEnd(),
        entry.trim(),
        ...(rest.trim() === "" ? [] : [rest.trim()]),
      ].join("\n\n")}\n`;
      assert.equal(update(text), expected, `the changelog at ${commit}`);
    }
  });
  const sections040 = releasedSections.slice(
    0,
    releasedSections.indexOf("## [0.3.0]"),
  );
  const draft040 = history.find(([commit]) => commit === "17f53b3a")[1];
  assert.ok(
    draft040.includes("### Features") && draft040.includes("### Bug Fixes"),
    "the last draft holds the staged subsections",
  );
  assert.equal(
    update(draft040, sections040),
    `${realHead}\n${releasedSections}`,
    "the 0.4.0 draft and the real entry give the released changelog",
  );

  // 8. After the formatter runs, the top-level headings of the older releases must be the headings that were there.
  // Each stub stands for a formatter that rewrites the older releases. Release headings are `## [0.3.0]` and
  // `## [0.2.0]`.
  const twoReleases = `${head}- Draft\n\n${release}\n\n- Previous\n\n## [0.2.0] - 2025-06-18\n\n- Older\n`;
  const refusedByFormatter = [
    {
      name: "a formatter that indents the first older release by four spaces",
      body: "sed 's/^## \\[0.3.0\\]/    ## [0.3.0]/'",
      expected: "2 [0.4.0] - 2026-06-15",
      found: "2 [Unreleased]",
    },
    {
      name: "a formatter that changes the level of an older release",
      body: "sed 's/^## \\[0.3.0\\]/### [0.3.0]/'",
      expected: "2 [0.3.0] - 2025-09-15",
      found: "3 [0.3.0] - 2025-09-15",
    },
    {
      name: "a formatter that changes the text of an older release",
      body: "sed 's/^## \\[0.2.0\\]/## [0.2.1]/'",
      expected: "2 [0.2.0] - 2025-06-18",
      found: "2 [0.2.1] - 2025-06-18",
    },
    {
      name: "a formatter that drops an older release heading",
      body: "grep -v '^## \\[0.2.0\\]'",
      expected: "2 [0.4.0] - 2026-06-15",
      found: "2 [Unreleased]",
    },
  ];
  checkCases(refusedByFormatter, ({ body, expected, found }) => {
    withFormatterScript(body, () =>
      assert.throws(() => update(twoReleases), {
        message: changedRefusal(expected, found),
      }),
    );
  });
  // A formatter that closes an open fence at the end of the text. A new entry with a fence that never closes swallows
  // the older release, and the formatter writes it as code. The same holds for the real prettier.
  const oneRelease = `${head}- Draft${previous}`;
  const openEntry = "## [0.4.0] - 2026-06-15\n\n```md\nExample";
  const swallowed = changedRefusal("2 [0.4.0] - 2026-06-15", "2 [Unreleased]");
  withFormatterScript("cat\nprintf '```\\n'", () =>
    assert.throws(() => update(oneRelease, openEntry), { message: swallowed }),
  );
  assert.throws(
    () => update(oneRelease, openEntry),
    { message: swallowed },
    "a new entry with an open fence, with the real prettier",
  );
  // A heading that stands in a list item or a block quote is not a section, so a formatter that changes it is no
  // reason to refuse. The older releases here hold a nested heading, and the stub changes it.
  const nested = `${head}- Draft\n\n${release}\n\n1. Step\n\n   ### Nested\n\n- Previous\n`;
  withFormatterScript("sed 's/### Nested/#### Nested/'", () =>
    assert.equal(
      update(nested),
      "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n* Added x\n\n## [0.3.0] - 2025-09-15\n\n1. Step\n\n   #### Nested\n\n- Previous\n",
      "a nested heading is not a section",
    ),
  );
  withFormatterScript("cat", () => {
    assert.equal(
      update(twoReleases),
      "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n* Added x\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n\n## [0.2.0] - 2025-06-18\n\n- Older\n",
      "a formatter that keeps the headings",
    );
    // With no older release below the draft there is nothing to check.
    assert.equal(
      update(`${head}- Draft\n`, openEntry),
      "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n```md\nExample\n",
      "no older release, no check",
    );
  });
  // The self-healing paths keep their older releases the same way.
  for (const text of [`# Changelog${previous}`, previous.trimStart()]) {
    assert.throws(
      () => update(text, openEntry),
      { message: swallowed },
      `a new entry with an open fence, without an Unreleased heading: ${JSON.stringify(text)}`,
    );
  }

  // The headings of the new entry count too, in order. A new entry that repeats an older release heading, or its own
  // heading, in a form that the generator does not demote (an indent) and then opens a fence or a comment that never
  // closes, hides the real older release inside the fence or the comment. The repeat must not stand in for it. This
  // holds on all three paths, with the real prettier and with a formatter that prints its input.
  const repeatedEntries = [
    [
      "a repeat of an older release, then a fence that never closes",
      "## [0.4.0] - 2026-06-15\n\n- New\n\n ## [0.3.0] - 2025-09-15\n\n~~~text\nExample",
    ],
    [
      "a repeat of an older release, then a comment that never closes",
      "## [0.4.0] - 2026-06-15\n\n- New\n\n ## [0.3.0] - 2025-09-15\n\n<!-- notes",
    ],
    [
      "a repeat of the entry heading, then a fence that never closes",
      "## [0.4.0] - 2026-06-15\n\n- New\n\n ## [0.4.0] - 2026-06-15\n\n```text\nExample",
    ],
  ];
  const olderTexts = [
    ["with an Unreleased heading", `${head}- Draft${previous}`],
    ["with a title and no Unreleased heading", `# Changelog${previous}`],
    ["with no title", previous.trimStart()],
  ];
  const repeatedCases = [];
  for (const [entryName, repeatedEntry] of repeatedEntries) {
    for (const [pathName, text] of olderTexts) {
      for (const formatter of ["prettier", "identity"]) {
        repeatedCases.push({
          name: `${entryName}, ${pathName}, ${formatter}`,
          entry: repeatedEntry,
          text,
          formatter,
        });
      }
    }
  }
  checkCases(repeatedCases, (testCase) => {
    const run = () => update(testCase.text, testCase.entry);
    assert.throws(
      () =>
        testCase.formatter === "identity" ? withIdentityFormatter(run) : run(),
      { message: swallowed },
    );
  });
  // A repeat that closes is not refused: the headings are the headings that were there.
  assert.deepEqual(
    topLevelHeadingsOf(
      update(
        oneRelease,
        "## [0.4.0] - 2026-06-15\n\n- New\n\n ## [0.3.0] - 2025-09-15\n\n- A repeat",
      ),
    ),
    [
      "1 Changelog",
      "2 [Unreleased]",
      "2 [0.4.0] - 2026-06-15",
      "2 [0.3.0] - 2025-09-15",
      "2 [0.3.0] - 2025-09-15",
    ],
    "a closed repeat of an older release is not refused",
  );
  // A link definition below the older releases makes `[0.4.0]` a link in the formatted text. The heading of the entry
  // reads the same with and without it.
  const footer =
    "[Unreleased]: https://example.com/u\n[0.4.0]: https://example.com/4\n[0.3.0]: https://example.com/3\n";
  assert.equal(
    update(`${head}- Draft${previous}\n${footer}`),
    `${released}\n${footer}`,
    "link definitions below the older releases",
  );
  // A reference link or image in a heading of the new entry is a link or an image only when a definition below the
  // older releases defines it. The heading reads the same alone and in the formatted text.
  const referenceEntry =
    "## [0.4.0] - 2026-06-15\n\n### ![Architecture][diagram]\n\n### [Details][docs]\n\n- Added x";
  const definitions =
    "[diagram]: https://example.com/d.png\n[docs]: https://example.com/docs\n";
  assert.equal(
    update(`${head}- Draft${previous}\n${definitions}`, referenceEntry),
    `# Changelog\n\n## [Unreleased]\n\n${referenceEntry}\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n\n${definitions}`,
    "reference links and images in the headings of the new entry",
  );
}

/**
 * Which heading lines the update anchors on. It drops the draft under the anchor, and Communique 1.1.3 reads a draft
 * only under `## [Unreleased]`, `## Unreleased` and `## [Unreleased](...)`. A draft under another spelling would go
 * with nothing to carry it into the new entry. So the update anchors on `## [Unreleased]` and `## Unreleased` (and the
 * same two as an H3), as the runner did before it used a parser, and on no other spelling. Without an anchor the entry
 * goes under the title, and the whole text stays.
 */
async function testUnreleasedAnchor() {
  const entry = "## [0.4.0] - 2026-06-15\n\n* Added x";
  const update = (content) =>
    new runner.UnreleasedAwareChangelog({
      changelogEntry: entry,
    }).updateContent(content);
  const older = "## [0.3.0] - 2025-09-15\n\n- Previous\n";
  const title = "# Changelog";

  // The lines that anchor. The draft goes, and the text that main wrote is the text that the update writes.
  const anchors = [
    "## [Unreleased]",
    "## Unreleased",
    "## [Unreleased]  ",
    "## Unreleased\t ",
  ];
  withIdentityFormatter(() => {
    for (const line of anchors) {
      const text = `${title}\n\n${line}\n\n- Draft\n\n${older}`;
      assert.equal(
        update(text),
        `${title}\n\n${line.trimEnd()}\n\n${entry}\n\n${older}`,
        `the draft under ${JSON.stringify(line)} goes`,
      );
      assert.equal(
        update(text),
        textThatMainWrites(text, entry).written,
        `main anchored on ${JSON.stringify(line)} too`,
      );
    }
  });

  // The lines that do not anchor, with a draft below each. The entry goes under the title, below a new anchor, and
  // every line of the text stays. Main did not anchor on any of them but the last two, which Communique does not read,
  // so main dropped the draft below those two. Communique does not read a draft under any of them either. The lines
  // that Communique reads a draft under and the update does not anchor on (a link, an indent) are refused instead (see
  // `testUnreleasedDraftEnd`).
  const notAnchors = [
    ["bold", "## **Unreleased**"],
    ["emphasis with underscores", "## _Unreleased_"],
    ["emphasis with a star", "## *Unreleased*"],
    ["code", "## `Unreleased`"],
    ["an escape", "## \\[Unreleased\\]"],
    [
      "a reference link",
      "## [Unreleased][]",
      "\n[Unreleased]: https://example.com/compare/v0.3.0...HEAD\n",
    ],
    ["two spaces after the marks", "##  [Unreleased]"],
    ["a tab after the marks", "##\t[Unreleased]"],
    ["a closing sequence", "## [Unreleased] ##"],
    ["a setext heading", "Unreleased\n----------"],
    ["a bracketed setext heading", "[Unreleased]\n============"],
    ["more text", "## Unreleased changes"],
    ["text before", "## Not Unreleased"],
    ["a date", "## [Unreleased] - 2026-06-15"],
    ["another case", "## unreleased"],
    ["capitals", "## [UNRELEASED]"],
    ["an H1", "# [Unreleased]"],
    ["an H4", "#### [Unreleased]"],
    ["an open bracket", "## [Unreleased"],
    ["a closing bracket", "## Unreleased]"],
  ].map(([name, line, footer = ""]) => ({ name, line, footer }));
  checkCases(notAnchors, ({ line, footer }) => {
    const text = `${title}\n\n${line}\n\n- Draft\n\n${older}${footer}`;
    withIdentityFormatter(() =>
      assert.equal(
        update(text),
        `${title}\n\n## [Unreleased]\n\n${entry}\n\n${text.slice(title.length).trim()}\n`,
        "the whole text stays below the new entry",
      ),
    );
  });

  // The first heading that anchors counts. A spelling that does not anchor, above an anchor, stays with its draft.
  // Communique refuses a changelog with two Unreleased headings before this update runs, and a second heading ends the
  // draft of the update at a heading that is no version (see `testUnreleasedDraftEnd`), so the update refuses it too.
  const twoHeadings = `${title}\n\n## [Unreleased]\n\n- First\n\n## Unreleased\n\n- Second\n\n${older}`;
  assert.throws(
    () => withMissingFormatter(() => update(twoHeadings)),
    {
      message: endMismatchRefusal(
        placeIn(twoHeadings, "## Unreleased"),
        placeIn(twoHeadings, "## [0.3.0] - 2025-09-15"),
      ),
    },
    "two Unreleased headings",
  );
  withIdentityFormatter(() => {
    assert.equal(
      update(
        `${title}\n\n## **Unreleased**\n\n- A\n\n## [Unreleased]\n\n- B\n\n${older}`,
      ),
      `${title}\n\n## **Unreleased**\n\n- A\n\n## [Unreleased]\n\n${entry}\n\n${older}`,
      "an Unreleased heading that does not anchor, above one that does",
    );
    assert.equal(
      update(`${title}\n\n## [Unreleased]\n\n- Draft\n\n## [0.3.0]\n`),
      `${title}\n\n## [Unreleased]\n\n${entry}\n\n## [0.3.0]\n`,
      "an older release with no text",
    );
  });

  // Communique reads no draft under an H3 anchor, so the update refuses a draft there, whatever it holds. A release
  // heading of any level under the anchor is a draft too, so it is refused and not dropped. An empty draft is fine,
  // and the releases below stay.
  const levelCases = [];
  for (const anchor of ["### [Unreleased]", "### Unreleased"]) {
    for (const [name, draft] of [
      ["a list", "- Draft"],
      ["a paragraph", "Draft text."],
      ["an H4 subsection", "#### Added\n\n- Draft"],
      ["an H4 release", "#### [0.3.0] - 2025-09-15\n\n- ACTUAL_OLDER_BODY"],
      ["a code block", "    code"],
    ]) {
      levelCases.push({
        name: `${name} under ${anchor}`,
        anchor,
        draft,
        first: draft.split("\n")[0],
      });
    }
  }
  const levelTexts = levelCases.map(
    ({ anchor, draft }) =>
      `${title}\n\n${anchor}\n\n${draft}\n\n## [0.2.0] - 2025-06-18\n\n- Older\n`,
  );
  const levelFormatted = formatDocuments(levelTexts);
  checkCases(levelCases, (testCase) => {
    const index = levelCases.indexOf(testCase);
    for (const [label, text] of [
      ["raw", levelTexts[index]],
      ["after prettier", levelFormatted[index]],
    ]) {
      const number = lineNumberOf(text, testCase.first);
      assert.ok(number > 0, `${label}: the text holds the draft`);
      assert.throws(
        () => withMissingFormatter(() => update(text)),
        { message: levelRefusal(3, number, testCase.first) },
        label,
      );
    }
  });
  for (const anchor of ["### [Unreleased]", "### Unreleased"]) {
    for (const [name, blanks] of [
      ["no line", ""],
      ["blank lines", "\n\n\n"],
    ]) {
      assert.equal(
        update(
          `${title}\n\n${anchor}\n${blanks}\n### [0.3.0] - 2025-09-15\n\n- Previous\n\n## [0.2.0] - 2025-06-18\n\n- Older\n`,
        ),
        `${title}\n\n${anchor}\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n### [0.3.0] - 2025-09-15\n\n- Previous\n\n## [0.2.0] - 2025-06-18\n\n- Older\n`,
        `${anchor} with ${name}: the releases stay`,
      );
    }
    assert.equal(
      update(`${title}\n\n${anchor}`),
      `${title}\n\n${anchor}\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n`,
      `${anchor} at the end of the text`,
    );
  }
}

/** The markers (`MK1`, `MK2`, ...) of a text, in order. The tests put one marker in each line of text that must not be lost or written twice. */
function markersIn(text) {
  return text.match(/MK\d+/g) ?? [];
}

/**
 * The markers that Communique 1.1.3 reads in the Unreleased draft of each text, with the real binary behind a fake
 * Anthropic API: an array of markers in order, or null when Communique reads no draft. Communique sends the draft to the
 * model, so the fake reads it in the request. A few workers run in parallel, each with its own repository and server.
 */
async function readDraftMarkersWithCommunique(texts) {
  const results = new Array(texts.length);
  let next = 0;
  const gitEnv = {
    PATH: process.env.PATH,
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_AUTHOR_NAME: "test",
    GIT_AUTHOR_EMAIL: "test@example.invalid",
    GIT_COMMITTER_NAME: "test",
    GIT_COMMITTER_EMAIL: "test@example.invalid",
  };
  const worker = async () => {
    const root = mkdtempSync(join(tmpdir(), "communique-draft-"));
    let lastRequest = null;
    const server = http.createServer((req, res) => {
      const chunks = [];
      req.on("data", (chunk) => chunks.push(chunk));
      req.on("end", () => {
        const request = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        lastRequest = JSON.stringify(request.messages);
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
                input: {
                  changelog: "### Added\n\nGenerated.",
                  release_title: "Title",
                  release_body: "Body",
                },
              },
            ],
            stop_reason: "tool_use",
            usage: { input_tokens: 1, output_tokens: 1 },
          }),
        );
      });
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    try {
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
      while (next < texts.length) {
        const index = next;
        next += 1;
        writeFileSync(join(root, "CHANGELOG.md"), texts[index]);
        lastRequest = null;
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
            `http://127.0.0.1:${server.address().port}`,
            "--output",
            join(root, "notes.md"),
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
        assert.notEqual(lastRequest, null, "communique must send a request");
        results[index] = lastRequest.includes(
          "Existing Unreleased CHANGELOG.md Draft",
        )
          ? markersIn(lastRequest)
          : null;
      }
    } finally {
      server.closeAllConnections();
      server.close();
      rmSync(root, { recursive: true, force: true });
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(6, texts.length) }, () => worker()),
  );
  return results;
}

/** The markers in the Unreleased draft that the runner's reader of Communique finds, or null for no draft. */
function draftMarkersOfPort(text) {
  const found = runner.findCommuniqueDraft(text);
  if (found === null) {
    return null;
  }
  return markersIn(
    text.slice(
      found.anchor.offset + found.anchor.line.length,
      found.end === null ? text.length : found.end.offset,
    ),
  );
}

/** The first line of `text` that holds `marker`, as `{ number, line }`. */
function placeOfMarker(text, marker) {
  const line = text
    .split(/\r\n|\r|\n/)
    .find((candidate) => candidate.includes(marker));
  assert.notEqual(line, undefined, `the text holds ${marker}`);
  return placeIn(text, line);
}

/**
 * Where the update and Communique end the Unreleased draft, and where they find its heading. The update ends the draft
 * at the next heading of level 1 or 2 that a Markdown parser reads. Communique 1.1.3 reads the changelog line by line
 * and ends its draft only at a line that, once trimmed, is `## ` and a version: a digit and a dot, or `v`, a digit and
 * a dot, in brackets or not. It finds its draft under a trimmed line `## [Unreleased]`, `## Unreleased` or
 * `## [Unreleased](...)`. If the two end the draft at different lines, the lines in between are written twice (the update
 * keeps what Communique folds into the new entry) or lost (the update drops what Communique never read). So the update
 * refuses unless both end the draft at the same line. Each case here is checked against the real Communique binary,
 * and against the reader in the runner, before the update is.
 */
async function testUnreleasedDraftEnd() {
  const entry = "## [0.4.0] - 2026-06-15\n\n* Added x";
  const update = (content) =>
    new runner.UnreleasedAwareChangelog({
      changelogEntry: entry,
    }).updateContent(content);
  const title = "# Changelog";
  const release = "## [0.3.0] - 2025-09-15";
  const nbsp = "\u00a0";
  // The text of a case: a draft of two paragraphs around `line`, and the older release. Communique reads MK1, and MK3
  // too when it does not end its draft at `line`. `MK2` is on the heading line.
  const endText = (line, before = "MK1.", join = "\n\n") =>
    `${title}\n\n## [Unreleased]\n\n${before}${join}${line}\n\nMK3.\n\n${release}\n\n- MK9\n`;

  // 1. The cases. { name, line, ends, accepted, before, join, formatted }: `ends` is true when Communique ends its draft at
  // `line`, `accepted` when the update takes the text, `before` and `join` put the line after a paragraph that it
  // continues, and `formatted` holds the same two flags for the text after prettier (when they differ).
  const endCases = [
    // Both end the draft at the version heading.
    ...[
      ["a version heading", "## [0.2.0] - 2026-02-02 MK2"],
      ["a version with no brackets", "## 0.2.0 MK2"],
      ["a version with a v", "## v0.2.0 MK2"],
      ["a bracketed version with a v", "## [v0.2.0] MK2"],
      ["a version of two parts", "## 1.2 MK2"],
      ["a version with a prerelease", "## 0.2.0-rc.1 MK2"],
      ["a heading that is a version to Communique", "## 1. Install MK2"],
      ["a bracketed version that is a number and a dot", "## [1.] MK2"],
      ["an indent of one space", " ## [0.2.0] MK2"],
      ["an indent of three spaces", "   ## [0.2.0] MK2"],
      ["two spaces after the marks", "##  [0.2.0] MK2"],
      ["a closing sequence", "## [0.2.0] MK2 ##"],
      ["blanks after the heading", "## [0.2.0] MK2   "],
      // The version is the text up to the first blank, and it needs a dot and a first digit, nothing more.
      ["a byte order mark inside the version", "## 1\ufeff.2 MK2"],
      ["a version with a letter before the dot", "## 1x.y MK2"],
    ].map(([name, line]) => ({ name, line, ends: true, accepted: true })),
    // Neither ends the draft at the line, so both end it at the older release.
    ...[
      ["no space after the marks", "##[0.2.0] MK2"],
      ["a no-break space after the marks", `##${nbsp}[0.2.0] MK2`],
      ["a zero width space before the marks", "\u200b## [0.2.0] MK2"],
      ["a byte order mark before the marks", "\ufeff## [0.2.0] MK2"],
      ["an H3 version heading", "### [0.2.0] MK2"],
    ].map(([name, line]) => ({ name, line, ends: false, accepted: true })),
    // The update ends the draft at an H1 or an H2 that Communique reads past: its text below is written twice.
    ...[
      ["an H2 with no version", "## Upgrade notes MK2"],
      ["an H2 with a name that is not a version", "## v1 MK2"],
      ["an H2 with a date", "## 2026-02-02 MK2"],
      ["an H2 with a space after the bracket", "## [ 0.2.0] MK2"],
      ["an H2 with a bracket that never closes", "## [0.2.0 MK2"],
      // A version ends at the first blank, or at the closing bracket.
      ["an H2 with a space inside the version", "## 1 .2 MK2"],
      ["an H2 with a tab inside the version", "## 1\t.2 MK2"],
      ["an H2 with a no-break space inside the version", "## 1\u00a0.2 MK2"],
      ["an H2 with a bracketed number and a dot after it", "## [1] 2.0 MK2"],
      ["an H2 with a name that starts with a letter", "## x1.2 MK2"],
      ["an H2 with a capital V", "## V1.2 MK2"],
      // A digit is an ASCII digit, and a blank is a Unicode blank: NEL ends the version, a byte order mark does not.
      ["an H2 with an Arabic-Indic digit", "## \u0661.2 MK2"],
      ["an H2 with a NEL inside the version", "## 1\u0085.2 MK2"],
      ["an H2 with a second closing bracket", "## [1] x.] MK2"],
      ["an H1 with a version", "# [0.2.0] - 2026-02-02 MK2"],
      ["an H1 with no version", "# Top MK2"],
    ].map(([name, line]) => ({ name, line, ends: false, accepted: false })),
    {
      name: "a tab after the marks",
      line: "##\t[0.2.0] - 2026-02-02 MK2",
      ends: false,
      accepted: false,
      // Prettier writes one space.
      formatted: { ends: true, accepted: true },
    },
    {
      name: "a setext H1 with a version",
      line: "0.2.0 MK2\n=====",
      ends: false,
      accepted: false,
      formatted: { ends: false, accepted: false },
    },
    {
      name: "a setext H2 with a version",
      line: "0.2.0 MK2\n-----",
      ends: false,
      accepted: false,
      // Prettier writes an ATX H2.
      formatted: { ends: true, accepted: true },
    },
    // Communique ends the draft at a line that the update reads as text, so the update drops the lines below it.
    ...[
      ["a no-break space before a version heading", `${nbsp}## [0.2.0] MK2`],
      ["an ideographic space before a version heading", "\u3000## [0.2.0] MK2"],
    ].map(([name, line]) => ({ name, line, ends: true, accepted: false })),
    {
      name: "a line of the draft paragraph with four spaces of indent",
      line: "    ## [0.2.0] MK2",
      before: "MK1. Some text.",
      join: "\n",
      ends: true,
      accepted: false,
      // Prettier joins the line into the paragraph.
      formatted: { ends: false, accepted: true },
    },
    {
      name: "a line of the draft paragraph with a tab of indent",
      line: "\t## [0.2.0] MK2",
      before: "MK1. Some text.",
      join: "\n",
      ends: true,
      accepted: false,
      formatted: { ends: false, accepted: true },
    },
  ];
  // Cases for the reader alone: the update refuses these for other reasons, or takes them for no reason in this test.
  const readerOnlyCases = [
    // These two lines hold no marker, so Communique reads the marker below them.
    { name: "an empty H2", line: "##", ends: false, reads: ["MK1", "MK3"] },
    { name: "an empty H1", line: "#", ends: false, reads: ["MK1", "MK3"] },
    { name: "a version in a list item", line: "- ## [0.2.0] MK2", ends: false },
    {
      name: "a version in a block quote",
      line: "> ## [0.2.0] MK2",
      ends: false,
    },
    // CommonMark reads this as a setext H1, and Communique ends its draft at its first line, as the update does. Nobody
    // writes this: prettier makes it an H1 that Communique does not end at, and the update refuses the text anyway,
    // because it trims the no-break space off the older releases and the formatter check sees the heading change.
    {
      name: "a setext H1 that Communique trims to a version heading",
      line: `${nbsp}## 0.2.0 MK2\n=====`,
      ends: true,
    },
    {
      name: "a version in a code fence",
      line: "```\n## [0.2.0] MK2\n```",
      ends: true,
    },
    {
      name: "a version in a comment",
      line: "<!--\n## [0.2.0] MK2\n-->",
      ends: true,
    },
  ];
  // The lines that anchor the draft of Communique, and the update does not anchor on: Communique reads a draft under
  // each, and the update would add a second heading and keep the draft.
  const communiqueAnchors = [
    ["a link", "## [Unreleased](https://example.com/compare/v0.3.0...HEAD)"],
    ["an indent of one space", " ## [Unreleased]"],
    ["an indent of three spaces", "   ## [Unreleased]"],
    ["an indent of four spaces", "    ## [Unreleased]"],
    ["a no-break space before the marks", `${nbsp}## [Unreleased]`],
    ["a code fence", "```\n## [Unreleased]\n```"],
    ["a comment", "<!--\n## [Unreleased]\n-->"],
  ].map(([name, anchor]) => ({ name, anchor, reads: ["MK1"] }));
  // The lines that anchor neither reader.
  const otherAnchors = [
    ["two spaces after the marks", "##  [Unreleased]"],
    ["a tab after the marks", "##\t[Unreleased]"],
    ["a tab after the marks, no brackets", "##\tUnreleased"],
    ["a closing sequence", "## [Unreleased] ##"],
    ["bold", "## **Unreleased**"],
    ["an H1", "# [Unreleased]"],
    ["an H3", "### [Unreleased]"],
    ["a list item", "- ## [Unreleased]"],
  ].map(([name, anchor]) => ({ name, anchor, reads: null }));
  const anchorText = (anchor) =>
    `${title}\n\n${anchor}\n\nMK1.\n\n${release}\n\n- MK9\n`;
  // A text with a line break that is a bare CR: Communique splits lines at LF only and finds no heading.
  const bareCr = `${title}\r\r## [Unreleased]\r\rMK1.\r\r${release}\r\r- MK9\r`;

  // 2. The reader of the runner reads what the real Communique reads.
  const readerTexts = [
    ...[...endCases, ...readerOnlyCases].map(
      ({ line, before, join, ends, reads }) => ({
        text: endText(line, before, join),
        reads: reads ?? (ends ? ["MK1"] : ["MK1", "MK2", "MK3"]),
      }),
    ),
    ...[...communiqueAnchors, ...otherAnchors].map(({ anchor, reads }) => ({
      text: anchorText(anchor),
      reads,
    })),
    { text: bareCr, reads: null },
  ];
  const readerNames = [
    ...[...endCases, ...readerOnlyCases].map(({ name }) => name),
    ...[...communiqueAnchors, ...otherAnchors].map(
      ({ name }) => `anchor: ${name}`,
    ),
    "a bare CR as line break",
  ];
  const real = await readDraftMarkersWithCommunique(
    readerTexts.map(({ text }) => text),
  );
  checkCases(
    readerTexts.map(({ text, reads }, index) => ({
      name: readerNames[index],
      text,
      reads,
      real: real[index],
    })),
    ({ text, reads, real: realReads }) => {
      assert.deepEqual(realReads, reads, "the real Communique");
      assert.deepEqual(
        draftMarkersOfPort(text),
        reads,
        "the reader of the runner",
      );
    },
  );

  // 3. The update takes a text only when both end the draft at one line, and then nothing is lost or written twice.
  // The markers that Communique does not read are the markers that the update writes, and the text that main wrote
  // is the text that the update writes when main lost and doubled nothing.
  const nothingLostOrTwice = (text, written) => {
    assert.deepEqual(
      markersIn(written).sort(),
      markersIn(text)
        .filter((marker) => !(draftMarkersOfPort(text) ?? []).includes(marker))
        .sort(),
      "the update drops what Communique reads and keeps the rest",
    );
    assert.deepEqual(
      draftMarkersOfPort(written),
      [],
      "Communique reads an empty draft in the text that the update writes",
    );
  };
  const endTexts = endCases.map(({ line, before, join }) =>
    endText(line, before, join),
  );
  const endFormatted = formatDocuments(endTexts);
  let comparedWithMain = 0;
  withIdentityFormatter(() => {
    checkCases(endCases, (testCase) => {
      const index = endCases.indexOf(testCase);
      for (const [label, text, flags] of [
        ["raw", endTexts[index], testCase],
        ["after prettier", endFormatted[index], testCase.formatted ?? testCase],
      ]) {
        if (flags.accepted) {
          const written = update(text);
          nothingLostOrTwice(text, written);
          const main = textThatMainWrites(text, entry).written;
          const mainIsSound =
            JSON.stringify(markersIn(main).sort()) ===
            JSON.stringify(markersIn(written).sort());
          if (mainIsSound) {
            comparedWithMain += 1;
            assert.equal(written, main, `${label}: the text of main`);
          }
          continue;
        }
        const row = placeOfMarker(text, "MK2");
        const older = placeIn(text, release);
        assert.throws(
          () => update(text),
          {
            message: flags.ends
              ? endMismatchRefusal(older, row)
              : endMismatchRefusal(row, older),
          },
          label,
        );
      }
    });
  });
  assert.ok(
    comparedWithMain >= 20,
    `${comparedWithMain} accepted texts were compared with main`,
  );

  // 4. The anchors. Communique reads a draft under each of these lines, and the update does not anchor on any of them,
  // so it refuses the text: it would add a second Unreleased heading and keep the draft that Communique reads.
  checkCases(communiqueAnchors, ({ anchor }) => {
    const text = anchorText(anchor);
    const communiqueLine = anchor
      .split("\n")
      .find((line) => /Unreleased/.test(line));
    assert.throws(() => withMissingFormatter(() => update(text)), {
      message: anchorMismatchRefusal(null, placeIn(text, communiqueLine)),
    });
  });
  // Neither reads a draft under the lines of `otherAnchors`, so the text goes under the title as before.
  withIdentityFormatter(() =>
    checkCases(
      otherAnchors.filter(({ anchor }) => !anchor.startsWith("###")),
      ({ anchor }) => {
        const text = anchorText(anchor);
        assert.equal(
          update(text),
          `${title}\n\n## [Unreleased]\n\n${entry}\n\n${text.slice(title.length).trim()}\n`,
        );
      },
    ),
  );
  // The update anchors on a heading that Communique does not read a draft under, and the draft is empty, so there is
  // nothing to drop (an H3 anchor with a draft is refused for that).
  withIdentityFormatter(() => {
    assert.equal(
      update(
        `${title}\n\n### [Unreleased]\n\n## [0.3.0] - 2025-09-15\n\n- MK9\n`,
      ),
      `${title}\n\n### [Unreleased]\n\n${entry}\n\n## [0.3.0] - 2025-09-15\n\n- MK9\n`,
      "an empty draft under an H3 anchor",
    );
  });
  // A text with bare CR line breaks: the update reads three lines, and Communique one with no heading. The update
  // refuses the draft, as it would drop text that Communique never read.
  assert.throws(
    () => withMissingFormatter(() => update(bareCr)),
    {
      message: anchorMismatchRefusal(
        { number: 3, line: "## [Unreleased]" },
        null,
      ),
    },
    "a bare CR as line break",
  );
  // Two anchors for Communique (it refuses such a changelog before this update runs): the update compares with the first.
  const twoAnchors = `${title}\n\n ## [Unreleased]\n\nMK1.\n\n## [Unreleased]\n\nMK2.\n\n${release}\n\n- MK9\n`;
  assert.throws(
    () => withMissingFormatter(() => update(twoAnchors)),
    {
      message: anchorMismatchRefusal(
        placeIn(twoAnchors, "## [Unreleased]"),
        placeIn(twoAnchors, " ## [Unreleased]"),
      ),
    },
    "two anchors",
  );
  // An H3 anchor with an empty draft is fine only when Communique reads no draft anywhere in the text.
  const h3AndLink = `${title}\n\n### [Unreleased]\n\n## [Unreleased](https://e.x)\n\nMK1.\n\n${release}\n\n- MK9\n`;
  assert.throws(
    () => withMissingFormatter(() => update(h3AndLink)),
    {
      message: anchorMismatchRefusal(
        placeIn(h3AndLink, "### [Unreleased]"),
        placeIn(h3AndLink, "## [Unreleased](https://e.x)"),
      ),
    },
    "an H3 anchor and a link anchor",
  );
  // The update drops the draft to the end of the text when no heading ends it, and Communique ends it at a line that
  // the parser reads as text.
  const lazyToEnd = `${title}\n\n## [Unreleased]\n\nMK1.\n    ## [0.2.0] MK2\n\nMK3.\n`;
  assert.throws(
    () => withMissingFormatter(() => update(lazyToEnd)),
    {
      message: endMismatchRefusal(
        null,
        placeIn(lazyToEnd, "    ## [0.2.0] MK2"),
      ),
    },
    "a draft that runs to the end of the text",
  );
  // A bare CR makes the lines of the update and the lines of Communique differ, so the same line number is not the same
  // line. Here the update finds its anchor on line 2 after the CR and Communique on line 2 after the LF, and the update
  // ends its draft at the H2 on line 4 and Communique at the release on line 4.
  const crAnchor = `${title}\r## [Unreleased]\n ## [Unreleased]\n\nMK1.\n\n${release}\n\n- MK9\n`;
  assert.throws(
    () => withMissingFormatter(() => update(crAnchor)),
    {
      message: anchorMismatchRefusal(
        { number: 2, line: "## [Unreleased]" },
        { number: 2, line: " ## [Unreleased]" },
      ),
    },
    "the same line number for another anchor",
  );
  const crEnd = `${title}\n## [Unreleased]\nMK1.\r## Notes MK2\n${release}\n\n- MK9\n`;
  assert.throws(
    () => withMissingFormatter(() => update(crEnd)),
    {
      message: endMismatchRefusal(
        { number: 4, line: "## Notes MK2" },
        { number: 4, line: release },
        true,
      ),
    },
    "the same line number for another end",
  );
  // Both ends are the same line of text, and a bare CR hides one of the two copies from Communique: the lines match by
  // their text and differ by their place.
  const crSameText = `${title}\n\n## [Unreleased]\n\n- MK1\r${release}\n- MK2\n\n${release}\n\n- MK9\n`;
  assert.throws(
    () => withMissingFormatter(() => update(crSameText)),
    {
      message: endMismatchRefusal(
        { number: 6, line: release },
        { number: 8, line: release },
        true,
      ),
    },
    "the same line text for another end",
  );
}

// A differential test against commonmark.js. The assertions above hold single examples, but a rule can also go wrong
// for a multi-character input that no example thought of. This test builds top-level documents from fence, heading,
// text and blank lines with random suffixes (code units, escapes and character references), indents, and line
// endings. A fixed seed makes the documents the same on every run. `findLineOutsideFences` and
// `normalizeCommuniqueBody` must agree with commonmark.js on each of them. It leaves out list items, block quotes and
// HTML blocks, which the runner does not track.
const DIFFERENTIAL_SEED = 466;
const DIFFERENTIAL_DOCUMENTS = 10000;

/** A small seeded generator (mulberry32): the same seed gives the same numbers. */
function createRandom(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let mixed = Math.imul(state ^ (state >>> 15), state | 1);
    mixed ^= mixed + Math.imul(mixed ^ (mixed >>> 7), mixed | 61);
    return ((mixed ^ (mixed >>> 14)) >>> 0) / 4294967296;
  };
}

// Run lengths that sit on or just past a round cap: 100, 200, 255, 256, 1,000, 4,096, 65,535 and 100,000.
const LONG_RUNS = [
  99, 100, 101, 199, 200, 201, 255, 256, 257, 1000, 1001, 4096, 65535, 65536,
  100_000,
];
// Every printable ASCII character: `!` to `~`.
const PRINTABLE = Array.from({ length: 0x7f - 0x21 }, (_, k) =>
  String.fromCharCode(0x21 + k),
).join("");
// Code units that look like a blank or a line break. A tab is a blank after a fence and in an info string, but not
// as indent. The rest are neither.
const LOOKALIKES = [
  "\t",
  "\v",
  "\f",
  "\u001c",
  "\u00a0",
  "\u0085",
  "\u1680",
  "\u2003",
  "\u2028",
  "\u2029",
  "\u200b",
  "\u3000",
  "\ufeff",
];
// Sequences that look like an escape or a character reference for a marker or a blank. CommonMark reads an info string
// and the text after a closer literally, so none of them changes what a fence line is.
const SEQUENCES = [
  "\\",
  "&",
  "\\`",
  "\\~",
  "\\\\`",
  "&#96;",
  "&#x60;",
  "&grave;",
  "&amp;`",
  "&#126;",
  "&#32;",
  "&#9;",
  "&nbsp;",
];

/**
 * commonmark.js 0.31.2 opens a backtick fence for "```x<U+2028>`", but the spec says a backtick info string cannot
 * hold a backtick, and markdown-it 14 agrees with the spec and with the runner. The cause: commonmark.js checks the
 * info string with `(?!.*`)`, and `.` stops at U+2028 and U+2029. So its answer is wrong, and a differential test
 * must not encode it. The generator leaves out a backtick fence line with a backtick after a U+2028 or U+2029. The
 * fixed cases in `testFenceTracking` check that shape against the spec.
 */
function hitsCommonmarkJsBug(line) {
  if (!/^ {0,3}`{3,}/.test(line)) {
    return false;
  }
  const separator = line.search(/[\u2028\u2029]/);
  return separator !== -1 && line.indexOf("`", separator) !== -1;
}

/** Makes the lines of one document. `coverage` counts the shapes that the document holds. */
function generateLines(random, coverage) {
  const pick = (list) => list[Math.floor(random() * list.length)];
  const letter = () =>
    pick("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ");
  const codeUnit = () => {
    let code = Math.floor(random() * 0x10000);
    while (code === 0x0a || code === 0x0d) {
      code = Math.floor(random() * 0x10000);
    }
    return String.fromCharCode(code);
  };
  // Up to three spaces, and now and then one more code unit: a look-alike, a printable character, or any code unit.
  // The code unit stands before the spaces or after one to three of them.
  // `>` starts a block quote, and `+`, `-` and `*` start a list item when spaces follow. The runner tracks neither,
  // so those four are left out.
  const indent = () => {
    const spaces = pick(["", "", "", " ", "  ", "   "]);
    if (random() >= 0.15) {
      return spaces;
    }
    let extra = pick([pick(LOOKALIKES), pick(PRINTABLE), codeUnit()]);
    if (">+-*".includes(extra)) {
      extra = "\u3000";
    }
    coverage.oddIndent += 1;
    if (random() < 0.5) {
      return extra + spaces;
    }
    coverage.spacedIndent += 1;
    return pick([" ", "  ", "   "]) + extra;
  };
  // Up to four pieces: blanks, markers, words, escapes, character references and single code units, so a suffix can be
  // "", " ~", "\tjs ~", "`a " or "&#96;\\`".
  // Now and then one piece repeats for a very long run, so that no cap on an info string or on trailing blanks passes.
  const suffix = () => {
    if (random() < 0.04) {
      coverage.longSuffix += 1;
      return pick([
        "x",
        "x",
        "x",
        " ",
        "\t",
        "~",
        "ab",
        " x",
        codeUnit(),
      ]).repeat(pick(LONG_RUNS));
    }
    let text = "";
    for (let count = Math.floor(random() * 5); count > 0; count -= 1) {
      const piece = pick([
        " ",
        "\t",
        "~",
        "`",
        "js",
        "x",
        " ",
        "\u2028",
        "\u2029",
        pick(LOOKALIKES),
        pick(SEQUENCES),
        pick(SEQUENCES),
        codeUnit(),
      ]);
      if (SEQUENCES.includes(piece)) {
        coverage.sequences += 1;
      }
      text += piece;
    }
    return text;
  };
  // Marker runs from 2 to 10, and now and then a long one.
  const markers = () => {
    if (random() < 0.02) {
      coverage.longMarkers += 1;
      return pick(["`", "~"]).repeat(
        pick([20, 100, 101, 255, 256, 257, 1000, 1001, 4096]),
      );
    }
    return pick(["`", "~"]).repeat(pick([2, 3, 3, 3, 4, 4, 5, 6, 10]));
  };
  const fence = () => {
    for (;;) {
      const text = indent() + markers() + suffix();
      if (!hitsCommonmarkJsBug(text)) {
        return text;
      }
    }
  };
  const line = () => {
    const kind = random();
    if (kind < 0.45) {
      return fence();
    }
    if (kind < 0.65) {
      return pick([
        "## Real",
        "## Real",
        "## Other",
        "# Title",
        "### Sub",
        "## Real ",
        " ## Real",
      ]);
    }
    if (kind < 0.8) {
      return pick(["", "", " ", "\t"]);
    }
    if (kind < 0.9) {
      // An indent of four spaces or a tab makes a code line or a continuation, never a fence.
      return pick(["    ", "\t"]) + pick(["```", "~~~", "## Real", "x"]);
    }
    let text = letter();
    for (let count = Math.floor(random() * 4); count > 0; count -= 1) {
      text += codeUnit();
    }
    return text;
  };
  const lines = [];
  for (let count = 1 + Math.floor(random() * 12); count > 0; count -= 1) {
    lines.push(line());
  }
  return lines;
}

/**
 * Joins `lines` with a random line ending after each one: LF, CR LF, or CR (a CR LF instead of it when `bareCr` is
 * false).
 */
function joinWithEndings(random, lines, bareCr = true) {
  let text = "";
  lines.forEach((line, index) => {
    text += line;
    if (index < lines.length - 1) {
      const kind = random();
      text += kind < 0.5 ? "\n" : kind < 0.8 || !bareCr ? "\r\n" : "\r";
    }
  });
  return text;
}

/** What commonmark.js says about `text`: the lines it sees, the lines inside a fenced code block, and the headings. */
function readWithCommonmark(text) {
  const lines = text.split(/\r\n|\r|\n/);
  // A final line ending ends the last line. It does not start another, empty one.
  if (lines.length > 1 && lines[lines.length - 1] === "") {
    lines.pop();
  }
  const fenced = new Set();
  const headings = [];
  const walker = new commonmark.Parser().parse(text).walker();
  for (let event = walker.next(); event; event = walker.next()) {
    const { entering, node } = event;
    if (!entering) {
      continue;
    }
    const [[firstLine], [lastLine]] = node.sourcepos ?? [[0], [0]];
    if (node.type === "code_block" && node.info !== null) {
      for (let line = firstLine; line <= lastLine; line += 1) {
        fenced.add(line - 1);
      }
    }
    if (node.type === "heading") {
      let literal = "";
      for (let child = node.firstChild; child; child = child.next) {
        literal += child.literal ?? "";
      }
      headings.push({ level: node.level, line: firstLine - 1, text: literal });
    }
  }
  return { lines, fenced, headings };
}

/** A document for an assertion message: the seed and the index repeat it, so a long one is cut short. */
function describeDocument(text) {
  const shown = JSON.stringify(text);
  return shown.length <= 400
    ? shown
    : `${shown.slice(0, 400)}... (${text.length} code units)`;
}

async function testFenceDifferential() {
  const random = createRandom(DIFFERENTIAL_SEED);
  const coverage = {
    longMarkers: 0,
    longSuffix: 0,
    oddIndent: 0,
    sequences: 0,
    skippedBodies: 0,
    spacedIndent: 0,
  };
  const anyLine = () => true;
  const isReal = (line) => line === "## Real";

  // Single code units are checked in `testFenceTracking`, but two together can still break a rule, as in "\\`" or
  // "&#96;". So every pair of a tab or a printable ASCII character, and each sequence of `SEQUENCES`, goes after the
  // markers of an opener and of a closer, and commonmark.js says what each line is.
  const blanksAndPrintable = ["\t", " ", ...PRINTABLE];
  const sequences = [
    ...blanksAndPrintable.flatMap((first) =>
      blanksAndPrintable.map((second) => first + second),
    ),
    ...SEQUENCES,
    ...SEQUENCES.map((sequence) => ` ${sequence}`),
  ];
  for (const marker of ["```", "~~~"]) {
    for (const sequence of sequences) {
      for (const lines of [
        [marker + sequence, "## Real", marker, "## Real"],
        [marker, "## Real", marker + sequence, "## Real", marker, "## Real"],
      ]) {
        const { fenced } = readWithCommonmark(lines.join("\n"));
        assert.equal(
          runner.findLineOutsideFences(lines, 0, isReal),
          lines.findIndex((line, i) => isReal(line) && !fenced.has(i)),
          `the fence lines ${JSON.stringify(lines)}`,
        );
      }
    }
  }

  for (let index = 0; index < DIFFERENTIAL_DOCUMENTS; index += 1) {
    const text = joinWithEndings(random, generateLines(random, coverage));
    const where = `document ${index} of seed ${DIFFERENTIAL_SEED}: ${describeDocument(text)}`;
    const { lines, fenced, headings } = readWithCommonmark(text);

    // From every start, the first line that is outside every fenced code block.
    for (let start = 0; start <= lines.length; start += 1) {
      let expected = -1;
      for (
        let line = start;
        line < lines.length && expected === -1;
        line += 1
      ) {
        expected = fenced.has(line) ? -1 : line;
      }
      assert.equal(
        runner.findLineOutsideFences(lines, start, anyLine),
        expected,
        `findLineOutsideFences from ${start} in ${where}`,
      );
    }
    // The lines that are a real `## Real` heading.
    const real = new Set(
      headings
        .filter((heading) => heading.level === 2 && isReal(lines[heading.line]))
        .map((heading) => heading.line),
    );
    const found = [];
    for (let start = 0; start < lines.length; ) {
      const line = runner.findLineOutsideFences(lines, start, isReal);
      if (line === -1) {
        break;
      }
      found.push(line);
      start = line + 1;
    }
    assert.deepEqual(
      found,
      [...real].sort((a, b) => a - b).filter((line) => !fenced.has(line)),
      `headings in ${where}`,
    );

    // `normalizeCommuniqueBody` demotes every level-2 heading that is not in a fence, and keeps every line ending.
    // `trim` can strip a U+2028, U+2029 or other blank from the front of the first line, so that line can then show
    // the commonmark.js bug shape. Those documents have no valid expected value here.
    const trimmed = text.trim();
    const body = readWithCommonmark(trimmed);
    if (body.lines.some(hitsCommonmarkJsBug)) {
      coverage.skippedBodies += 1;
      continue;
    }
    const endings = trimmed.match(/\r\n|\r|\n/g) ?? [];
    const expectedBody = body.lines
      .map((line, i) => {
        const demote =
          body.headings.some(
            (heading) => heading.level === 2 && heading.line === i,
          ) && line.startsWith("## ");
        return (demote ? `### ${line.slice(3)}` : line) + (endings[i] ?? "");
      })
      .join("")
      .trim();
    assert.equal(
      runner.normalizeCommuniqueBody(text),
      expectedBody,
      `normalizeCommuniqueBody in ${where}`,
    );
  }

  // A generator that stops making a shape would silently stop testing it, so each shape must show up.
  assert.ok(
    coverage.skippedBodies <= DIFFERENTIAL_DOCUMENTS / 100,
    `documents left out of the normalizeCommuniqueBody check: ${coverage.skippedBodies}`,
  );
  assert.ok(
    coverage.longSuffix >= 100,
    `long info strings and long blanks: ${coverage.longSuffix}`,
  );
  assert.ok(
    coverage.longMarkers >= 100,
    `long marker runs: ${coverage.longMarkers}`,
  );
  assert.ok(
    coverage.oddIndent >= 1000,
    `lines with an extra code unit as indent: ${coverage.oddIndent}`,
  );
  assert.ok(
    coverage.spacedIndent >= 500,
    `lines with an extra code unit after spaces: ${coverage.spacedIndent}`,
  );
  assert.ok(
    coverage.sequences >= 1000,
    `escapes and character references after the markers: ${coverage.sequences}`,
  );
}

/** The texts after one run of the real prettier, as `mise run format` writes them. */
function formatDocuments(texts) {
  const directory = mkdtempSync(join(tmpdir(), "format-documents-"));
  try {
    const files = texts.map((text, index) => {
      const file = join(directory, `${index}.md`);
      writeFileSync(file, text);
      return file;
    });
    execFileSync(runner.resolvePrettierBin(), ["--write", ...files], {
      cwd: directory,
      stdio: "pipe",
    });
    return files.map((file) => readFileSync(file, "utf8"));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

// A property test of `updateContent`. The documents hold a title, an Unreleased heading, a draft that is made of random
// fragments, and two older releases that the generator places itself. So the judge does not use the reader of the
// update: whatever the draft holds, the update must refuse, or write a changelog in which the two older releases are
// still the last top-level headings, with their lines. A draft of paragraphs, lists and H3 headings only must be
// written, and it must give main's text byte for byte. A fixed seed makes the documents the same on every run.
const UPDATER_SEED = 522;
const UPDATER_DOCUMENTS = 200;
const UPDATER_FORMATTED_DOCUMENTS = 60;
const UPDATER_PRETTIER_DOCUMENTS = 12;
const OLDER_RELEASES =
  "## [0.3.0] - 2025-09-15\n\n- Previous three\n\n## [0.2.0] - 2025-06-18\n\n- Previous two\n";
const OLDER_HEADINGS = ["2 [0.3.0] - 2025-09-15", "2 [0.2.0] - 2025-06-18"];

/**
 * One fragment of a draft: [lines, plain]. A plain fragment is a paragraph, a list or an H3 heading with inline text.
 * The other fragments hold a block that the update does not read, or a heading that ends the draft where a reader of
 * lines sees none. `fragments` counts the fragments by name.
 */
function generateDraftFragment(random, fragments) {
  const pick = (list) => list[Math.floor(random() * list.length)];
  const words = (count) =>
    Array.from({ length: count }, () =>
      pick([
        "alpha",
        "beta",
        "fix",
        "add",
        "use",
        "the",
        "plugin",
        "diff",
        "now",
      ]),
    ).join(" ");
  const bullet = () => pick(["-", "*", "+"]);
  const plain = [
    [
      "a paragraph",
      () => [`${words(5)}.`, ...(random() < 0.5 ? [`${words(3)}.`] : [])],
    ],
    [
      "a flat list",
      () => [`${bullet()} ${words(2)}`, `${bullet()} ${words(3)}`],
    ],
    ["a nested list", () => ["- a", "  - b", "    - c", "- d"]],
    ["an ordered list", () => ["1. one", "   - nested", "2. two"]],
    [
      "a subsection",
      () => [
        `### ${pick(["Added", "Fixed", "Changed", "Bug Fixes"])}`,
        "",
        "- thing",
      ],
    ],
    [
      "inline markup",
      () => [
        "- Use `code`, <kbd>K</kbd> and [link](https://x.y/z) ![i](a.png)",
      ],
    ],
    ["an issue line", () => ["- Fixed the crash", "#123 and the hang"]],
    ["a loose list", () => ["- one", "", "- two", "", "  more"]],
  ];
  const other = [
    ["an H4 heading", () => ["#### Detail", "", "- thing"]],
    [
      "an H6 release heading",
      () => ["###### [0.9.0] - 2025-12-01", "", "- Old nine"],
    ],
    ["a setext H1", () => ["Title", "====="]],
    ["a setext H2", () => ["Title", "-----"]],
    // Communique ends its draft at an indented version heading, as the update does, and the runner before #531 did not see it.
    ["an indented H2", () => [" ## [0.9.0] - 2025-12-01", "", "- Old nine"]],
    [
      "an H2 that is indented by three spaces",
      () => ["   ## [0.9.0] - 2025-12-01", "", "- Old nine"],
    ],
    [
      "an indented H2 after a list",
      () => ["- note", "", " ## [0.9.0] - 2025-12-01", "", "- Old nine"],
    ],
    ["an indented H2 that is no version", () => [" ## Notes", "", "- note"]],
    ["an H2 with a tab", () => ["##\tNotes", "", "- note"]],
    ["an H2", () => ["## Upgrade notes", "", "- note"]],
    ["an empty H2", () => ["##", "", "- note"]],
    [
      "a no-break space before an H2",
      () => ["\u00a0## [0.9.0] - 2025-12-01", "", "- Old nine"],
    ],
    ["a lazy indented H2", () => ["Some text", "    ## [0.9.0]"]],
    ["an H1", () => ["# Top"]],
    ["a div", () => ["<div>", "## inner", "</div>"]],
    [
      "details with a fence",
      () => ["<details>", "# inner", "```text", "</details>"],
    ],
    ["an open comment", () => ["<!-- open"]],
    ["a pre element", () => ["<pre>", "## inner"]],
    ["a block quote", () => ["> note"]],
    ["a fence in a block quote", () => ["> ```", "> ## inner", "> ```"]],
    ["an H2 in a block quote", () => ["> ## inner"]],
    ["an indented code block", () => ["    code"]],
    ["an indented fence", () => ["    ```", "    code"]],
    ["a tab-indented list", () => ["\t- item"]],
    ["an open fence", () => ["```text", "code", "## inner"]],
    ["a closed fence", () => ["```text", "code", "```"]],
    ["a long fence", () => ["````md", "```", "````"]],
    ["a tilde fence", () => ["~~~", "code"]],
    ["a thematic break", () => [pick(["---", "***", "___", "- - -"])]],
    ["a link definition", () => ["[x]: https://example.com"]],
    ["an H2 in a list item", () => ["- ## inner", "", "  - thing"]],
    ["a fence in a list item", () => ["- item", "", "  ```js", "  x", "  ```"]],
    ["a plus list that holds an equals line", () => ["+ item", "=", "+ item"]],
  ];
  const kind = random() < 0.55 ? plain : other;
  const [name, build] = pick(kind);
  fragments[name] = (fragments[name] ?? 0) + 1;
  return [build(), kind === plain];
}

/** Makes one document: [text, plain]. The lines end with LF or CR LF. */
function generateUpdaterDocument(random, fragments, lineCoverage) {
  const lines = [
    "# Changelog",
    "",
    random() < 0.3 ? "## Unreleased" : "## [Unreleased]",
    "",
  ];
  let plain = true;
  for (let count = Math.floor(random() * 4); count > 0; count -= 1) {
    const [fragment, isPlain] = generateDraftFragment(random, fragments);
    lines.push(...fragment, ...(random() < 0.6 ? [""] : []));
    plain = plain && isPlain;
  }
  // The lines of the line-reader differential, with some of the fences left in.
  if (random() < 0.2) {
    lines.push(...generateLines(random, lineCoverage), "");
    plain = false;
  }
  lines.push(...OLDER_RELEASES.split("\n"));
  // Communique ends a line at LF only, so a bare CR can hide a heading from it. Such a document mostly tests that
  // refusal (see `testUnreleasedDraftEnd`).
  return [joinWithEndings(random, lines, false), plain];
}

/**
 * The properties of `updateContent` for one document of `generateUpdaterDocument`, run with the formatter that the
 * caller chose. Returns "refused", "swallowed" (the text has no older release as a heading to begin with), "same" (main's
 * text), or "kept more" (main's kept lines are the end of the text, and more lines stay). `expectedFormat` turns the text that main builds into the text that the formatter gives.
 */
function checkUpdaterDocument(text, plain, where, expectedFormat) {
  const entry = "## [0.4.0] - 2026-06-15\n\n- Added x";
  let updated;
  try {
    updated = new runner.UnreleasedAwareChangelog({
      changelogEntry: entry,
    }).updateContent(text);
  } catch (error) {
    assert.match(
      error.message,
      /^(The Unreleased draft has (a code fence|a node that the update does not read|a line that no paragraph)|The update and Communique (end the Unreleased draft|find the Unreleased heading) in different places|The update would change the older releases)/,
      `the refusal in ${where}`,
    );
    assert.ok(
      !plain,
      `a draft of paragraphs, lists and H3 headings is read in ${where}`,
    );
    return "refused";
  }
  // A fence that the draft leaves open, and that is in the part that the update keeps, swallows the older releases in the
  // text itself. The update keeps that text as it was, and no property holds for it.
  if (
    topLevelHeadingsOf(text).slice(-2).join("|") !== OLDER_HEADINGS.join("|")
  ) {
    return "swallowed";
  }
  // Whatever the draft holds, the two older releases stay the last top-level headings, with their lines.
  assert.deepEqual(
    topLevelHeadingsOf(updated).slice(-2),
    OLDER_HEADINGS,
    `the older releases stay headings in ${where}`,
  );
  assert.ok(
    updated.includes("\n- Previous three\n") &&
      updated.includes("\n- Previous two\n"),
    `the older releases keep their lines in ${where}`,
  );
  // What the update wrote before this check.
  const { written, rest } = textThatMainWrites(text, entry);
  const main = expectedFormat(written);
  if (updated === main) {
    return "same";
  }
  assert.ok(
    !plain,
    `a draft of paragraphs, lists and H3 headings gives main's text in ${where}`,
  );
  assert.ok(
    updated.endsWith(expectedFormat(`${rest.trim()}\n`)) &&
      updated.length > main.length,
    `main's kept lines stay, and more with them, in ${where}`,
  );
  return "kept more";
}

async function testUnreleasedUpdaterProperty() {
  const random = createRandom(UPDATER_SEED);
  const fragments = {};
  const lineCoverage = {
    longMarkers: 0,
    longSuffix: 0,
    oddIndent: 0,
    sequences: 0,
    spacedIndent: 0,
  };
  const documents = [];
  while (documents.length < UPDATER_DOCUMENTS) {
    const [text, plain] = generateUpdaterDocument(
      random,
      fragments,
      lineCoverage,
    );
    // commonmark.js opens a backtick fence that the spec does not (see `hitsCommonmarkJsBug`).
    if (!text.split(/\r\n|\r|\n/).some(hitsCommonmarkJsBug)) {
      documents.push([text, plain]);
    }
  }
  const texts = documents.map(([text]) => text);

  // Raw, and after the real prettier, which the repo's format check applies to a changelog on main. The identity
  // formatter prints the text that the update builds. Prettier writes an indented heading at the start of a line, so
  // the formatted texts never keep more than main does.
  for (const [name, inputs, minimum] of [
    ["raw", texts, { refused: 20, same: 20, keptMore: 3, plainSame: 20 }],
    [
      "formatted",
      formatDocuments(texts.slice(0, UPDATER_FORMATTED_DOCUMENTS)),
      { refused: 5, same: 5, keptMore: 0, plainSame: 5 },
    ],
  ]) {
    const results = withIdentityFormatter(() =>
      inputs.map((text, index) =>
        checkUpdaterDocument(
          text,
          documents[index][1],
          `${name} updater document ${index} of seed ${UPDATER_SEED}: ${describeDocument(text)}`,
          (built) => built,
        ),
      ),
    );
    const count = (result, plainOnly = false) =>
      results.filter(
        (value, index) =>
          value === result && (!plainOnly || documents[index][1]),
      ).length;
    // Each outcome must occur, or the check would stop testing it.
    assert.ok(
      count("refused") > minimum.refused &&
        count("same") > minimum.same &&
        count("kept more") >= minimum.keptMore &&
        count("same", true) > minimum.plainSame &&
        count("swallowed") <= inputs.length / 5,
      `${name} updater documents: refused ${count("refused")}, same ${count("same")}, kept more ${count("kept more")}, plain and same ${count("same", true)}, swallowed ${count("swallowed")}, of ${inputs.length}`,
    );
  }
  // A generator that stops making a fragment would silently stop testing it.
  assert.ok(
    Object.keys(fragments).length >= 38,
    `fragments of the updater documents: ${JSON.stringify(fragments)}`,
  );

  // The real prettier on the first documents, raw. A refusal is a result, and so is a text that prettier changes.
  texts.slice(0, UPDATER_PRETTIER_DOCUMENTS).forEach((text, index) => {
    checkUpdaterDocument(
      text,
      documents[index][1],
      `real prettier, document ${index} of seed ${UPDATER_SEED}: ${describeDocument(text)}`,
      runner.formatChangelogMarkdown,
    );
  });
}

/**
 * `run-release-please.sh` can run the runner with a global `release-please` that it finds through `NODE_PATH`, and the
 * runner reads the changelog with `commonmark`. Without `commonmark` on that path the runner must fail at start-up,
 * before it reads the GitHub environment, so that it creates no release and no pull request. With it, the runner starts
 * and asks for the GitHub environment.
 */
async function testRunnerNeedsCommonmark() {
  const root = mkdtempSync(join(tmpdir(), "runner-fallback-"));
  try {
    const scriptDirectory = join(root, "scripts");
    const globalModules = join(root, "global", "node_modules");
    mkdirSync(scriptDirectory);
    mkdirSync(globalModules, { recursive: true });
    copyFileSync(
      join(__dirname, "release-please-runner.js"),
      join(scriptDirectory, "release-please-runner.js"),
    );
    symlinkSync(
      join(__dirname, "node_modules", "release-please"),
      join(globalModules, "release-please"),
    );
    const start = (nodePath) =>
      spawnSync(
        process.execPath,
        [join(scriptDirectory, "release-please-runner.js"), "--dry-run"],
        {
          encoding: "utf8",
          env: { NODE_PATH: nodePath, PATH: process.env.PATH },
        },
      );

    const without = start(globalModules);
    assert.equal(
      without.status,
      1,
      "the runner exits with 1 without commonmark",
    );
    assert.match(without.stderr, /Cannot find module 'commonmark'/);
    assert.doesNotMatch(
      without.stderr,
      /GITHUB_TOKEN must be set/,
      "the runner stops before it reads the GitHub environment",
    );

    const withCommonmark = start(
      `${globalModules}${delimiter}${join(__dirname, "node_modules")}`,
    );
    assert.equal(withCommonmark.status, 1);
    assert.match(withCommonmark.stderr, /GITHUB_TOKEN must be set/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
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
  await testUnreleasedDraftFenceGuard();
  await testUnreleasedDraftStructure();
  await testUnreleasedAnchor();
  await testUnreleasedDraftEnd();
  await testFenceDifferential();
  await testUnreleasedUpdaterProperty();
  await testRunnerNeedsCommonmark();
  testPullRequestOutputs();
  await testInternalCommitSkipsCommunique();
  await testReleasableCommitRunsCommunique();
  await testCommuniqueConfigFitsReleaseNotes();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

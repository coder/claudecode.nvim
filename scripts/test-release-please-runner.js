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
  // A four-backtick fence in the draft flipped the fence state for the rest of
  // the file, so the existing release below it was dropped.
  for (const [open, close] of [
    ["````md", "````"],
    ["~~~md", "~~~"],
  ]) {
    cases.push([
      `# Changelog\n\n## [Unreleased]\n\n${open}\n\`\`\`\n## Not a heading\n${close}${previous}`,
      released,
    ]);
  }
  // Text right after a closing fence, and a short fence inside a long one.
  cases.push([
    `# Changelog\n\n## [Unreleased]\n\n\`\`\`text\nExample\n\`\`\`\nText after the fence${previous}`,
    released,
  ]);
  cases.push([
    `# Changelog\n\n## [Unreleased]\n\n\`\`\`\`\n\`\`\`\n## Not a release\n\`\`\`\`${previous}`,
    released,
  ]);
  // Without an Unreleased heading the entry goes under the title, or under a new title.
  cases.push([`# Changelog${previous}`, released]);
  cases.push([
    "Existing text\n\nMore text\n",
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\nExisting text\n\nMore text\n",
  ]);
  // An Unreleased heading inside a fence is not the anchor.
  cases.push([
    "# Changelog\n\n````text\n```\n## [Unreleased]\n````\n\n## [Unreleased]\n\n- Draft\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n",
    "# Changelog\n\n````text\n```\n## [Unreleased]\n````\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n",
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
  }

  // One bare CR in an LF file: right after a closing fence, and inside an opener line.
  assert.equal(
    update(
      "# Changelog\n\n## [Unreleased]\n\n```text\nExample\n```\rText after the fence\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n",
    ),
    released,
  );
  assert.equal(
    update(
      "# Changelog\n\n## [Unreleased]\n\n````\r```\n## Not a release\n````\n\n## [0.3.0] - 2025-09-15\n\n- Previous\n",
    ),
    released,
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
 * The error of `updateContent` for a draft that holds a line like a release heading. Lines are numbered from 1, and a
 * line shows its first 80 code units.
 */
function refusal(lineNumber, line) {
  return (
    `The Unreleased draft has a line that looks like a release heading, and the update would drop it with the draft. Line ${lineNumber}: ${JSON.stringify(line.slice(0, 80))}. ` +
    "A code fence in the draft that does not close where you meant is the usual cause, and Prettier closes a fence that is still open at the end of the file. " +
    "Check the draft's code fences: a closing line uses the same character as the opener, at least as many of it, and has nothing after it but spaces or tabs. " +
    "If the line is only an example or a code comment, change it so that it does not look like a release heading."
  );
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
  // `update` refuses, and the error names `line`: the first line of the draft that looks like a release heading.
  const refuses = (text, line, name, run = update) => {
    assert.ok(lineOf(text, line) > 0, `${name}: the text holds the line`);
    assert.throws(
      () => run(text),
      { message: refusal(lineOf(text, line), line) },
      name,
    );
  };

  // A draft fence that CommonMark does not close runs to the end of the text, and it holds every older release
  // below it. The updater must not write a changelog without that release, whatever shape the fence has.
  const stayOpen = [
    ["a fence with no closer", "```text\nDraft\n"],
    ["a closer that is shorter than the opener", "````text\nDraft\n```\n"],
    ["a closer of the other marker", "```text\nDraft\n~~~\n"],
    ["a closer with text after it", "```text\nDraft\n``` done\n"],
  ];
  // A code block in the older release has a bare closer, and that line can close the draft fence. No fence is open at
  // the end then, but the older release still sits inside the draft fence.
  const olderWithCode =
    "\n\n## [0.3.0] - 2025-09-15\n\n```js\nconsole.log(1);\n```\n\n- Previous\n";
  for (const [name, draft] of stayOpen) {
    const raw = `${head}${draft}${previous}`;
    for (const ending of ["\n", "\r\n", "\r"]) {
      assert.throws(
        () => update(raw.replace(/\n/g, ending)),
        { message: refusal(lineOf(raw, release), release) },
        `${name}, ${JSON.stringify(ending)} endings`,
      );
    }
    refuses(
      `${head}${draft}${olderWithCode}`,
      release,
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
    refuses(formatted, release, `${name}, after prettier`);
  }

  // The loose reading of a release heading. Each form below is dropped with the draft when it stands in a draft fence
  // that does not close. `sectionStarts` are valid section starts outside a fence (the updater keeps them there), and
  // `notSectionStarts` are not (the updater takes them for draft text even without a fence). Each part of the
  // pattern has a form that pins it: the indent, the tab, the second space, the hash count, the brackets, `v` and
  // `V`, the dotted version, and what follows it.
  const sectionStarts = [
    "## 0.3.0",
    "## v0.3.0 - 2025-09-15",
    "# 1.0.0",
    "## [2026.11.9]",
    "## 1.0",
    "## [0.3.0](https://example.com/compare/v0.2.0...v0.3.0) (2025-09-15)",
    "##  [0.3.0] - 2025-09-15",
    "## V0.3.0",
    "## [0.5.0-rc.1] - 2026-11-01",
    "## 0.4.0-beta.1",
    "## 0.3.0+build.5",
    "# \t0.3.0",
  ];
  const notSectionStarts = [
    " ## [0.3.0] - 2025-09-15",
    "   ## 0.3.0",
    "    ## 0.3.0",
    "\t## 0.3.0",
    "##\t[0.3.0] - 2025-09-15",
    "### [0.3.0] - 2025-09-15",
    "#### 0.3.0",
    "###### 1.0",
    "0.3.0\n-----",
    "1.0\n---",
    "[0.3.0] - 2025-09-15\n=====",
    "v0.3.0\n=",
    "  V0.3.0\n  ---  ",
    "\t0.3.0\n\t===\t",
  ];
  for (const form of [...sectionStarts, ...notSectionStarts]) {
    const first = form.split("\n")[0];
    refuses(
      `${head}\`\`\`text\nDraft\n\n${form}\n\n- Previous\n`,
      first,
      `the form ${JSON.stringify(form)} in a draft fence`,
    );
  }
  // Without a fence the loose forms are draft text too. Prettier then writes most of them as a canonical heading, and
  // the updater keeps that. The others stay what they are: a heading that has three or more hashes or sits in an
  // indented code block still belongs to the draft. Prettier turns the last form into a paragraph and a thematic
  // break, which is no heading.
  const prettierSections = new Set([
    " ## [0.3.0] - 2025-09-15",
    "   ## 0.3.0",
    "##\t[0.3.0] - 2025-09-15",
    "0.3.0\n-----",
    "1.0\n---",
    "[0.3.0] - 2025-09-15\n=====",
    "v0.3.0\n=",
  ]);
  const prettierDraft = new Map([
    ["    ## 0.3.0", "    ## 0.3.0"],
    ["\t## 0.3.0", "    ## 0.3.0"],
    ["### [0.3.0] - 2025-09-15", "### [0.3.0] - 2025-09-15"],
    ["#### 0.3.0", "#### 0.3.0"],
    ["###### 1.0", "###### 1.0"],
    ["\t0.3.0\n\t===\t", "    0.3.0"],
  ]);
  for (const form of notSectionStarts) {
    const first = form.split("\n")[0];
    const raw = `${head}Draft\n\n${form}\n\n- Previous\n`;
    refuses(raw, first, `the form ${JSON.stringify(form)}, no fence`);
    const formatted = runner.formatChangelogMarkdown(raw);
    const name = `the form ${JSON.stringify(form)}, no fence, after prettier`;
    if (prettierSections.has(form)) {
      assert.ok(
        update(formatted)
          .split("\n")
          .some((line) => /^##? .*(?:0\.3\.0|1\.0)/.test(line)),
        `${name}: the heading is kept`,
      );
    } else if (prettierDraft.has(form)) {
      refuses(formatted, prettierDraft.get(form), name);
    } else {
      assert.equal(form, "  V0.3.0\n  ---  ", `${name}: the form is listed`);
      assert.ok(
        !/^#/m.test(formatted.slice(head.length)),
        `${name}: no heading`,
      );
    }
  }
  // A few of them after Prettier, in a fence that Prettier closes: the form stays as it is.
  for (const form of [
    "##  [0.3.0] - 2025-09-15",
    "##\t[0.3.0] - 2025-09-15",
    "## V0.3.0",
    "## [0.5.0-rc.1] - 2026-11-01",
    "  V0.3.0\n  ---  ",
  ]) {
    const raw = `${head}\`\`\`text\nDraft\n\n${form}\n\n- Previous\n`;
    const formatted = runner.formatChangelogMarkdown(raw);
    refuses(
      formatted,
      form.split("\n")[0],
      `the form ${JSON.stringify(form)} in a draft fence, after prettier`,
    );
  }

  // Where the dropped lines start and end: the first line after the heading, and the last line before the next
  // section, which may be the text line of a setext heading.
  refuses(
    "# Changelog\n\n## [Unreleased]\n  ## 0.3.0\n\n## [0.2.0] - 2025-06-18\n\n- Older\n",
    "  ## 0.3.0",
    "a release heading on the first line after the Unreleased heading",
  );
  refuses(
    "# Changelog\n\n## [Unreleased]\n\n  ## 0.3.0\n## [0.2.0] - 2025-06-18\n\n- Older\n",
    "  ## 0.3.0",
    "a release heading on the last line before the next section",
  );
  refuses(
    "# Changelog\n\n## [Unreleased]\n\n0.3.0\n---\n## [0.2.0] - 2025-06-18\n\n- Older\n",
    "0.3.0",
    "a setext release heading right before the next section",
  );
  refuses(
    `${head}\`\`\`text\nDraft\n\n## 0.3.0`,
    "## 0.3.0",
    "a release heading on the last line of a text that has no final newline",
  );
  // The next section stays. It is the first line that is kept.
  assert.equal(
    update(
      "# Changelog\n\n## [Unreleased]\n\nDraft\n## [0.2.0] - 2025-06-18\n\n- Older\n",
    ),
    "# Changelog\n\n## [Unreleased]\n\n## [0.4.0] - 2026-06-15\n\n- Added x\n\n## [0.2.0] - 2025-06-18\n\n- Older\n",
    "the next section is not part of the draft",
  );

  // The error names the first line. A draft example that repeats the version of the real release comes first.
  refuses(
    `${head}\`\`\`md\n## [0.3.0] - 2025-09-14\n\`\`\`\n\n\`\`\`text\nDraft\n${previous}`,
    "## [0.3.0] - 2025-09-14",
    "a draft example that repeats the version of a lost release is named first",
  );
  // A heading is cut at 80 code units in the message.
  const long = `## [0.3.0] - ${"x".repeat(100)}`;
  refuses(
    `${head}\`\`\`text\nDraft\n\n${long}\n\n- Previous\n`,
    long,
    "a long heading is cut at 80 code units",
  );

  // What the new entry shows does not matter, because only the dropped lines are read. A prerelease that is lost
  // behind a broken fence, and a new entry of the same version number or one that shows the lost heading as an
  // example, do not hide it.
  refuses(
    `${head}\`\`\`text\nDraft\n\n## [0.5.0-rc.1] - 2026-11-01\n\n- Candidate\n`,
    "## [0.5.0-rc.1] - 2026-11-01",
    "a lost prerelease of the new version",
    (text) => updateWith("## [0.5.0] - 2026-11-11\n\n- Final", text),
  );
  refuses(
    `${head}\`\`\`text\nDraft\n\n## [0.4.0-beta.1] - 2026-11-01\n\n- Beta\n`,
    "## [0.4.0-beta.1] - 2026-11-01",
    "a lost prerelease of a new prerelease of the same version",
    (text) => updateWith("## [0.4.0-beta.2] - 2026-11-11\n\n- Beta 2", text),
  );
  refuses(
    `${head}\`\`\`text\nDraft\n\n## [0.4.0] - 2026-11-09\n\n- Real\n`,
    "## [0.4.0] - 2026-11-09",
    "a new entry that shows the lost heading as an example",
    (text) =>
      updateWith(
        "## [0.5.0] - 2026-11-11\n\n```md\n## [0.4.0] - 2026-11-09\n```",
        text,
      ),
  );

  // The cost: a line in the dropped text that looks like a release heading is refused, even when it is an example
  // or a code comment and nothing older was lost. The runner cannot tell it from a release.
  for (const [name, text, line] of [
    [
      "a release heading in a code example of the draft",
      `${head}\`\`\`md\n## [1.0.0] - 2020-01-01\n\`\`\`${previous}`,
      "## [1.0.0] - 2020-01-01",
    ],
    [
      "a code comment that starts with a version",
      `${head}\`\`\`bash\n# 0.10 or newer\nnpm i\n\`\`\`${previous}`,
      "# 0.10 or newer",
    ],
    [
      "an H3 that starts with a version",
      `${head}### [1.0.0] - notes\n\n- Draft${previous}`,
      "### [1.0.0] - notes",
    ],
    [
      "an indented code block with a release heading",
      `${head}Example:\n\n    ## [1.0.0] - 2020-01-01\n${previous}`,
      "    ## [1.0.0] - 2020-01-01",
    ],
  ]) {
    refuses(text, line, name);
  }

  // Inputs that b477362 handled keep their output. Without an older release, an open fence loses nothing, even when
  // it holds a heading: the first release of a project can end its draft with a Markdown example.
  for (const [name, text, expected] of [
    [
      "a first release whose draft fence runs to the end and holds a ## heading",
      `${head}\`\`\`markdown\n## Usage\nCall the API.\n`,
      entryOnly,
    ],
    [
      "an open fence that holds a # comment, with nothing older",
      `${head}\`\`\`bash\n# install\nnpm i\n`,
      entryOnly,
    ],
    [
      "an open fence with no heading line",
      `${head}\`\`\`text\nDraft\n`,
      entryOnly,
    ],
    [
      "a closed fence that holds a heading example, with nothing older",
      `${head}\`\`\`md\n## Example\n\`\`\`\n`,
      entryOnly,
    ],
    [
      "a closed fence that holds a heading example, and an older release",
      `${head}\`\`\`md\n## Example\n\`\`\`${previous}`,
      released,
    ],
    [
      "a code example of the draft with an Unreleased heading",
      `${head}\`\`\`md\n## [Unreleased]\n\`\`\`${previous}`,
      released,
    ],
    [
      "a code example of the draft with a heading that has no dotted version",
      `${head}\`\`\`md\n## 3 reasons\n\`\`\`${previous}`,
      released,
    ],
    [
      "a mention of a release heading in a line of text",
      `${head}See ## [1.0.0] here.${previous}`,
      released,
    ],
    [
      "seven hashes and no space after the hash are not headings",
      `${head}####### 1.0.0\n\n#1.0 is the issue${previous}`,
      released,
    ],
    [
      "a line that starts with a version, with no underline below it",
      `${head}0.3.0 is out\n\n1.0.0\n- item\n\n2.0.0\n--- x${previous}`,
      released,
    ],
    [
      "a setext heading whose text has no dotted version",
      `${head}3 reasons\n-------${previous}`,
      released,
    ],
    [
      "a list item that starts with a version",
      `${head}- 0.3.0 fixed\n  ---${previous}`,
      released,
    ],
    [
      "an older release heading that prettier rewrites",
      `${head}Draft\n\n##  [0.3.0]  - 2025-09-15   ##\n\n- Previous\n`,
      released,
    ],
    [
      "a title and no Unreleased heading, with a heading example further down",
      `# Changelog${previous}\n\n\`\`\`md\n## [1.0.0]\n\`\`\`\n`,
      `${released}\n\`\`\`md\n## [1.0.0]\n\`\`\`\n`,
    ],
    ["no title", previous.trimStart(), released],
  ]) {
    assert.equal(update(text), expected, name);
  }
  // Only a release heading is protected. A non-release section behind an open fence cannot be told from the heading
  // example of the first release above, so it is dropped as before.
  assert.equal(
    update(`${head}\`\`\`text\nDraft\n\n## Upgrade notes\n\n- Read this\n`),
    entryOnly,
    "a section that is not a release is not protected",
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
const DIFFERENTIAL_UPDATER_DOCUMENTS = 30;

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

/** Joins `lines` with a random line ending after each one: LF, CR LF, or CR. */
function joinWithEndings(random, lines) {
  let text = "";
  lines.forEach((line, index) => {
    text += line;
    if (index < lines.length - 1) {
      const kind = random();
      text += kind < 0.5 ? "\n" : kind < 0.8 ? "\r\n" : "\r";
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

  // The existing sections of a changelog stay headings. The formatter prints its input (see `withIdentityFormatter`).
  // The real formatter runs in the updater tests above.
  const refused = withIdentityFormatter(() =>
    checkUpdaterDocuments(random, coverage),
  );
  // Both outcomes must occur, or the check would stop testing one of them.
  assert.ok(
    refused > 0 && refused < DIFFERENTIAL_UPDATER_DOCUMENTS,
    `updater documents that updateContent refused: ${refused} of ${DIFFERENTIAL_UPDATER_DOCUMENTS}`,
  );
}

function checkUpdaterDocuments(random, coverage) {
  const entry = "## [0.4.0] - 2026-06-15\n\n- Added x";
  const updater = new runner.UnreleasedAwareChangelog({
    changelogEntry: entry,
  });
  let refused = 0;
  for (let index = 0; index < DIFFERENTIAL_UPDATER_DOCUMENTS; index += 1) {
    const middle = generateLines(random, coverage);
    const text = joinWithEndings(random, [
      "# Changelog",
      "",
      "## [Unreleased]",
      "",
      ...middle,
      "",
      "## [0.3.0] - 2025-09-15",
      "",
      "- Previous",
      "",
    ]);
    const where = `updater document ${index} of seed ${DIFFERENTIAL_SEED}: ${describeDocument(text)}`;
    const { headings, lines } = readWithCommonmark(text);
    const unreleased = headings.findIndex(
      (heading) => heading.level === 2 && heading.text === "[Unreleased]",
    );
    assert.notEqual(
      unreleased,
      -1,
      `the Unreleased heading stays a heading in ${where}`,
    );
    // The draft body goes, so the headings from there up to the next level 1 or 2 heading go with it. The updater
    // looks for that heading at the start of a line, so an indented one does not end the draft.
    const next = headings.findIndex(
      (heading, i) =>
        i > unreleased &&
        heading.level <= 2 &&
        /^##? /.test(lines[heading.line]),
    );
    // The older release heading goes with the draft when nothing ends the draft before it. A fence can cause that:
    // the heading is then in the dropped part, and the updater refuses. A section that ends the draft first keeps it.
    const release = "## [0.3.0] - 2025-09-15";
    const releaseAt = lines.indexOf(release);
    if (next === -1 || releaseAt < headings[next].line) {
      assert.throws(
        () => updater.updateContent(text),
        { message: refusal(releaseAt + 1, release) },
        `refusal in ${where}`,
      );
      refused += 1;
      continue;
    }
    const expected = [
      ...headings.slice(0, unreleased + 1),
      { level: 2, text: "[0.4.0] - 2026-06-15" },
      ...(next === -1 ? [] : headings.slice(next)),
    ].map((heading) => `${heading.level} ${heading.text}`);
    const updated = readWithCommonmark(
      updater.updateContent(text),
    ).headings.map((heading) => `${heading.level} ${heading.text}`);
    assert.deepEqual(
      updated,
      expected,
      `headings after updateContent in ${where}`,
    );
  }
  return refused;
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
  await testFenceDifferential();
  testPullRequestOutputs();
  await testInternalCommitSkipsCommunique();
  await testReleasableCommitRunsCommunique();
  await testCommuniqueConfigFitsReleaseNotes();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

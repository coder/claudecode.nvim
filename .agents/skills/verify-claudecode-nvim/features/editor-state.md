# Report editor state

Claude asks Neovim about the user's editor before it acts. `getWorkspaceFolders` names the working directory, `getOpenEditors` lists the open files, `getDiagnostics` returns the errors and warnings an LSP or linter set, `checkDocumentDirty` tells whether a file has unsaved changes, and `saveDocument` writes a file. Each answers at once with JSON text in `result.content[0].text`.

## Sub-features

- `ed-folders` answers one folder for Neovim's current directory (`name`, `uri`, `path`) plus `rootPath`, and follows `:cd`.
- `ed-editors` lists each open file buffer with `label`, `fileName`, `uri`, `languageId`, `lineCount`, `isActive`, and `isDirty`.
- `ed-diag-all` answers every buffer's diagnostics as a list of `{uri, diagnostics}`, each with `message`, `severity` (`Error`, `Warning`, `Info`, `Hint`), a 0-based `range`, `source`, and `code`.
- `ed-diag-uri` with `uri` answers only that file, `[]` when it has no diagnostics, and error `-32001` `File not open` when no buffer has it.
- `ed-dirty` answers `"success":true` with `isDirty` and `isUntitled` for an open file, and `"success":false` with `Document not open: <filePath>` otherwise. The second is a normal answer, not a JSON-RPC error.
- `ed-save` writes the file, current or hidden, and answers `"saved":true` with `Document saved successfully`.
- `ed-save-fail` answers `"success":false` with a message that starts with `Failed to save file:` when `:write` fails.

## How to get to it (user POV)

- Claude calls `getWorkspaceFolders`, `getOpenEditors`, `getDiagnostics`, `checkDocumentDirty`, or `saveDocument` while the user works in Neovim.
- The answers follow what the user did: `:cd`, `:edit`, unsaved edits, `:set readonly`, and diagnostics from an LSP or linter.

## Driving it with vcn.sh

Preconditions:

- Launch with `$V launch -c 'lua vim.diagnostic.set(vim.api.nvim_create_namespace("vcn"), 0, {{lnum=1, col=0, end_col=4, severity=vim.diagnostic.severity.WARN, message="vcn test warning", source="vcn", code="VCN1"}})' hello.txt`. The `-c` command plays a linter that flags `beta` on line 2. It sets editor state, not a plugin path. The harness runs no language server, so without it every getDiagnostics answer is `[]`.
- `$V doctor` is all `ok`, and `$V expr 'luaeval("#vim.diagnostic.get(0)")'` prints `1`.
- Read an answer with `$V await <id> | jq -c '.result.content[0].text | fromjson'` and an error with `$V await <id> | jq -c .error`.

Steps:

- **Workspace folder.** Run `$V tool e1 getWorkspaceFolders`. The answer has `"success":true`, `rootPath` `<WORK>`, and one folder with `name` `work`, `path` `<WORK>`, and `uri` `file://<WORK>`.
- **Follow `:cd`.** Run `$V keys ':cd ..' Enter` and `$V until 'getcwd()' "$VCN_STATE"`. `$V tool e2 getWorkspaceFolders` answers `rootPath` `<VCN_STATE>`. Go back with `$V keys ':cd -' Enter` and `$V until 'getcwd()' "$WORK"`.
- **All diagnostics.** Run `$V tool e3 getDiagnostics`. The answer lists one file, `uri` `file://<WORK>/hello.txt`, with one diagnostic: `message` `vcn test warning`, `severity` `Warning`, `range` from `{line 1, character 0}` to `{line 1, character 4}`, `source` `vcn`, and `code` `VCN1`.
- **One file.** `$V tool e4 getDiagnostics "$(jq -nc --arg u "file://$WORK/hello.txt" '{uri:$u}')"` answers the same as e3. The same call for `other.txt` as `e5` answers error `-32001`, `File not open`, with `data` `File must be open to retrieve diagnostics: <WORK>/other.txt`.
- **Open editors.** Run `$V keys ':e other.txt' Enter`, `$V until "expand('%:t')" other.txt`, and `$V tool e6 getOpenEditors`. `jq -c '[.tabs[] | {label, isActive, isDirty, languageId, lineCount}]'` on its text prints `hello.txt` (not active, 3 lines) and `other.txt` (active, 4 lines), both not dirty, with `languageId` `text`. The e5 call again as `e7` now answers `[]`.
- **Dirty file.** Run `$V keys G o five Escape`, `$V until 'mode()' n`, `$V keys ':b hello.txt' Enter`, and `$V until "expand('%:t')" hello.txt`. `$V tool e8 checkDocumentDirty "$(jq -nc --arg p "$WORK/other.txt" '{filePath:$p}')"` answers `"success":true`, `"isDirty":true`, and `"isUntitled":false`. `getOpenEditors` shows `other.txt` with `"isDirty":true` and `"isActive":false`. The e8 call for `missing.txt` answers `"success":false` and `Document not open: <WORK>/missing.txt`.
- **Save a hidden file.** Record `sha256sum "$WORK/other.txt"`, then run `$V tool e11 saveDocument "$(jq -nc --arg p "$WORK/other.txt" '{filePath:$p}')"`. It answers `"success":true`, `"saved":true`, and `Document saved successfully`. `$V until "getbufvar('other.txt', '&modified')" 0` passes, `tail -n 1 "$WORK/other.txt"` prints `five`, the sha256 changed, and `$V doctor` stays all `ok`. Run `$V capture ed-save` and `$V screenshot ed-save`.
- **Save fails.** Run this last, because `readonly` stays set. Run `$V keys ':set ro' Enter`, record `sha256sum "$WORK/hello.txt"`, and run `$V tool e13 saveDocument "$(jq -nc --arg p "$WORK/hello.txt" '{filePath:$p}')"`. It answers `"success":false` with a message that starts with `Failed to save file:` and contains `E45`. The sha256 is unchanged.
- **Proof.** Keep each response with `$V await <id> > "$OUT/<sub-feature>-<id>.json"`, and end with `$V record editor-state`.

## Gotchas

- Key order in the JSON answers is not stable. Compare fields with jq, never the raw text.
- After `:cd`, getWorkspaceFolders follows the new directory, but `workspaceFolders` in `$VCN_STATE/claude/ide/$PORT.lock` keeps the launch directory.
- The `ed-save-fail` message also carries a Lua stack trace. Match only its start and the `E45` code.

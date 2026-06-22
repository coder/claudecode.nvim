-- Reproduction / verification for issue #285:
--   "[BUG] ClaudeCodeAdd fails when adding a file in a directory with a `$`"
--   https://github.com/coder/claudecode.nvim/issues/285
--
-- Root cause (one defect, two call sites): user-supplied file paths are passed
-- through vim.fn.expand(), which performs SHELL-STYLE EXPANSION -- including
-- environment-variable substitution. A real path segment like `$post` (common in
-- TanStack Router / file-based routing, e.g. `src/routes/$post/index.tsx`) is
-- read by expand() as the env var `$post`; since it is undefined, expand()
-- replaces it with the empty string. `src/routes/$post/index.tsx` therefore
-- becomes `src/routes//index.tsx`, which does not exist, so the subsequent
-- filereadable()/isdirectory() check fails:
--
--   * lua/claudecode/init.lua:1033  (the :ClaudeCodeAdd command)
--       file_path = vim.fn.expand(file_path)
--       if filereadable(file_path)==0 and isdirectory(file_path)==0 -> ERROR
--   * lua/claudecode/tools/open_file.lua:110  (the openFile MCP tool)
--       local file_path = vim.fn.expand(params.filePath)
--       if filereadable(file_path)==0 -> ERROR "File not found"
--
-- The command-line layer is NOT to blame: a user-command arg keeps its literal
-- `$` (verified separately); only expand() mangles it.
--
-- The proposed fix (from the reporter) is to use the existing
-- require("claudecode.utils").expand_tilde() helper, which expands a leading
-- `~`/`~/` but leaves `$`, globs, and every other character untouched. Scenario D
-- demonstrates that this helper preserves the `$` path while still expanding `~`.
--
-- This script drives the REAL :ClaudeCodeAdd command (registered via
-- M._create_commands()) and the REAL open_file.handler against ACTUAL files on
-- disk. No WebSocket server or Claude CLI is needed: the bug fires at the
-- expand()+filereadable() gate, before any send/broadcast. M.state.server is
-- stubbed truthy only to pass the "integration not running" guard, and
-- M.send_at_mention is stubbed so the control case can confirm it reached the
-- send path (i.e. passed the gate).
--
-- Run from the repo root:
--   nvim --headless -u NONE -l scripts/repro_issue_285.lua
--
-- Exit code: 1 if the bug is present (a file that EXISTS is rejected), 0 if fixed.
-- The detailed verdict is printed to stdout either way.

local script_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ":h:h")
vim.opt.rtp:prepend(repo_root)

local function out(msg)
  io.stdout:write(msg .. "\n")
end

local uv = vim.loop

-- ----------------------------------------------------------------------------
-- Arrange: real files on disk, one with a `$` segment, one without (control).
-- ----------------------------------------------------------------------------
local work = vim.fn.tempname() .. "_issue285"
local dollar_dir = work .. "/src/routes/$post"
local plain_dir = work .. "/src/routes/post"
local file_dollar = dollar_dir .. "/index.tsx"
local file_plain = plain_dir .. "/index.tsx"

vim.fn.mkdir(dollar_dir, "p")
vim.fn.mkdir(plain_dir, "p")
for _, f in ipairs({ file_dollar, file_plain }) do
  local fh = assert(io.open(f, "w"))
  fh:write("export default function Page() { return null }\n")
  fh:close()
end

-- Ground truth via libuv (raw syscall, performs NO `$`/`~` expansion): both
-- files genuinely exist on disk at their literal paths.
local function exists_on_disk(p)
  return uv.fs_stat(p) ~= nil
end
assert(exists_on_disk(file_dollar), "setup: $-path file was not created on disk")
assert(exists_on_disk(file_plain), "setup: control file was not created on disk")

-- ----------------------------------------------------------------------------
-- Capture logger output. `logger` is a module-level singleton table required by
-- init.lua, so replacing its functions here is seen by the command's closure.
-- ----------------------------------------------------------------------------
local logger = require("claudecode.logger")
local log = {} -- { {level=, component=, msg=}, ... }
local function capture(level)
  return function(component, ...)
    local parts = {}
    for _, v in ipairs({ ... }) do
      parts[#parts + 1] = tostring(v)
    end
    log[#log + 1] = { level = level, component = component, msg = table.concat(parts, " ") }
  end
end
logger.error = capture("error")
logger.warn = capture("warn")
logger.debug = capture("debug")
logger.info = capture("info")

local function last_error()
  for i = #log, 1, -1 do
    if log[i].level == "error" then
      return log[i].msg
    end
  end
  return nil
end
local function clear_log()
  log = {}
end

-- ----------------------------------------------------------------------------
-- Register the REAL commands and stub just enough to pass the run-state guard
-- and observe whether the send path was reached.
-- ----------------------------------------------------------------------------
local cc = require("claudecode")
cc.state = cc.state or {}
cc.state.server = { _stub = true } -- truthy: pass the "integration is not running" guard
cc.state.config = cc.state.config or {}

local sent = {}
cc.send_at_mention = function(file_path, start_line, end_line, context)
  sent[#sent + 1] = { file_path = file_path, start_line = start_line, end_line = end_line, context = context }
  return true, nil
end

cc._create_commands()

-- ----------------------------------------------------------------------------
-- Helpers to run the real command / real tool handler.
-- ----------------------------------------------------------------------------
local function run_add(path)
  clear_log()
  -- Invoke exactly as a mapping / file-explorer integration would: literal arg.
  vim.cmd({ cmd = "ClaudeCodeAdd", args = { path } })
end

local open_file = require("claudecode.tools.open_file")
local function run_open(path)
  local ok, err = pcall(open_file.handler, { filePath = path, makeFrontmost = false })
  return ok, err
end

-- ----------------------------------------------------------------------------
out("== issue #285 reproduction ($ in path mangled by vim.fn.expand) ==")
out(("Neovim: %s"):format(tostring(vim.version())))
out(("work dir: %s"):format(work))
out("")

-- Diagnostic: show exactly how expand() mangles the path vs the literal truth.
local expanded = vim.fn.expand(file_dollar)
out("-- mechanism --")
out(("  literal path        : %s"):format(file_dollar))
out(("  exists on disk (uv) : %s"):format(tostring(exists_on_disk(file_dollar))))
out(("  filereadable(literal): %d  (file functions do NOT expand $)"):format(vim.fn.filereadable(file_dollar)))
out(("  vim.fn.expand(...)   : %s"):format(expanded))
out(("  filereadable(expand) : %d  (<- expand() dropped the $post segment)"):format(vim.fn.filereadable(expanded)))
out("")

-- Scenario A: the issue. :ClaudeCodeAdd on a file that EXISTS but has a `$`.
run_add(file_dollar)
local a_err = last_error()
local a_reached_send = #sent > 0
out("[A] :ClaudeCodeAdd  <$-path file that exists>")
out(("  error logged : %s"):format(a_err or "(none)"))
out(("  reached send : %s"):format(tostring(a_reached_send)))
local a_bug = (a_err ~= nil) and not a_reached_send
out(("  => %s"):format(a_bug and "BUG: existing file rejected" or "ok: file accepted"))
out("")

-- Scenario B: control. Same command, sibling file WITHOUT `$`. Must always pass
-- the gate and reach the send path -- proves the harness is sound and the only
-- variable is the `$`.
sent = {}
run_add(file_plain)
local b_err = last_error()
local b_reached_send = #sent > 0
out("[B] :ClaudeCodeAdd  <control: same path, no $>")
out(("  error logged : %s"):format(b_err or "(none)"))
out(("  reached send : %s"):format(tostring(b_reached_send)))
out(("  => %s"):format(b_reached_send and "ok: file accepted (harness sound)" or "UNEXPECTED: control failed"))
out("")

-- Scenario C: the second call site -- the openFile MCP tool handler.
local c_ok, c_err = run_open(file_dollar)
local c_msg = type(c_err) == "table" and tostring(c_err.data or c_err.message) or tostring(c_err)
out("[C] openFile MCP tool handler  <$-path file that exists>")
if c_ok then
  out("  result       : opened (no error)")
else
  out(("  error thrown : %s"):format(c_msg))
end
local c_bug = (not c_ok) and c_msg:find("not found", 1, true) ~= nil
out(("  => %s"):format(c_bug and "BUG: existing file reported not found" or "ok: file accepted"))
out("")

-- Scenario E: regression guard. The documented `:ClaudeCodeAdd %` "add current
-- buffer" keymap (README) must keep working: expand_tilde alone would leave `%`
-- literal and the readability check would reject it. The fix still expands Vim's
-- %/#/<...> tokens via vim.fn.expand while keeping `$` paths intact.
sent = {}
vim.cmd("edit " .. vim.fn.fnameescape(file_plain))
run_add("%")
local e_err = last_error()
local e_reached_send = #sent > 0
local e_sent_path = e_reached_send and sent[#sent].file_path or nil
out("[E] :ClaudeCodeAdd %   <current-buffer token; README 'add current buffer' keymap>")
out(("  error logged : %s"):format(e_err or "(none)"))
out(("  reached send : %s  (resolved: %s)"):format(tostring(e_reached_send), tostring(e_sent_path)))
local e_bug = not e_reached_send
out(
  ("  => %s"):format(
    e_bug and "BUG: % current-buffer token rejected (regression)" or "ok: % expanded to current buffer"
  )
)
out("")

-- Scenario D: the proposed fix. expand_tilde() preserves `$` (and globs) while
-- still expanding a leading `~`.
local utils = require("claudecode.utils")
local et_dollar = utils.expand_tilde(file_dollar)
local home = os.getenv("HOME") or ""
local et_tilde = utils.expand_tilde("~/some/$dir/file.tsx")
out("-- proposed fix: require('claudecode.utils').expand_tilde --")
out(("  expand_tilde($-path)        : %s"):format(et_dollar))
out(("  filereadable(expand_tilde)  : %d  (<- $ preserved, file found)"):format(vim.fn.filereadable(et_dollar)))
out(("  expand_tilde('~/x/$dir/..') : %s"):format(et_tilde))
local tilde_ok = home ~= "" and et_tilde == (home .. "/some/$dir/file.tsx")
out(("  tilde still expands         : %s"):format(tilde_ok and "yes" or "(HOME unset; skipped)"))
out("")

-- ----------------------------------------------------------------------------
-- Verdict
-- ----------------------------------------------------------------------------
pcall(vim.fn.delete, work, "rf")

out("== verdict ==")
local reproduced = a_bug or c_bug
local regressed = e_bug
if not b_reached_send then
  out("WARNING: control scenario B failed; harness may be unsound -- treat results with care.")
end
if reproduced then
  out("BUG #285 REPRODUCED:")
  if a_bug then
    out("  - :ClaudeCodeAdd rejected an existing file because expand() dropped the $ segment.")
  end
  if c_bug then
    out("  - openFile MCP tool reported an existing file as 'not found' for the same reason.")
  end
  out("  Fix: route plain paths through claudecode.utils.expand_tilde() at both call sites.")
end
if regressed then
  out("REGRESSION: :ClaudeCodeAdd % no longer resolves the current buffer (the fix must")
  out("  still expand Vim's %/#/<...> tokens, only $-substitution should be dropped).")
end
if not reproduced and not regressed then
  out("FIXED: the $-path file is accepted by both :ClaudeCodeAdd and openFile,")
  out("       and the `%` current-buffer token still expands.")
end

io.stdout:flush()
vim.cmd("cquit " .. ((reproduced or regressed) and 1 or 0))

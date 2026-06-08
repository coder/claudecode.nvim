-- Regression gate for issue #228: focus_after_send + provider="none"/"external".
--
-- Run from the repo root:
--   nvim -u NONE -l fixtures/issue-228/repro.lua
-- (or: bash fixtures/issue-228/run.sh)
--
-- History: focus_after_send used to fail SILENTLY under provider="none"/"external"
-- (the focus call routes to a no-op provider). The fix does NOT make focus work
-- for those providers (it can't — Claude runs outside Neovim); instead it:
--   (c) warns ONCE at setup when focus_after_send=true and provider is none/external, and
--   (b) fires a `User ClaudeCodeSendComplete` autocmd on every connected send so users
--       can run their own focus logic (e.g. tmux select-pane).
-- This script verifies that fixed behavior, against the REAL plugin + REAL providers.

local script_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ":h:h:h")
vim.opt.runtimepath:prepend(repo_root)

local PASS = "PASS"
local FAIL = "FAIL"

-- Wipe every claudecode.* module so each scenario starts from clean state.
local function reset_modules()
  for name in pairs(package.loaded) do
    if name:match("^claudecode") then
      package.loaded[name] = nil
    end
  end
end

-- Custom provider TABLE (a fully-supported provider kind) that records whether a
-- focus/visibility action actually took effect.
local function recording_provider(record)
  return {
    setup = function() end,
    open = function()
      record.open_effect = true
    end,
    ensure_visible = function()
      record.ensure_visible_effect = true
    end,
    close = function() end,
    simple_toggle = function() end,
    focus_toggle = function() end,
    get_active_bufnr = function()
      return nil
    end,
    is_available = function()
      return true
    end,
  }
end

---@param opts table { name, provider, focus_after_send }
local function run_scenario(opts)
  reset_modules()

  local claudecode = require("claudecode")
  local logger = require("claudecode.logger")

  -- Capture the #228 setup warning (overridden BEFORE setup so we see it fire).
  local warnings = {}
  logger.warn = function(_, msg)
    table.insert(warnings, tostring(msg))
  end

  claudecode.setup({
    auto_start = false,
    log_level = "warn",
    track_selection = false,
    focus_after_send = opts.focus_after_send,
    terminal = { provider = opts.provider },
  })

  local terminal = require("claudecode.terminal")

  -- Instrument the REAL `none` provider to confirm focus_after_send still routes
  -- to a no-op there (the underlying limitation is unchanged; only the UX is).
  local calls = { open = 0, ensure_visible = 0 }
  if opts.provider == "none" then
    local none = require("claudecode.terminal.none")
    local real_open, real_ensure = none.open, none.ensure_visible
    none.open = function(...)
      calls.open = calls.open + 1
      return real_open(...)
    end
    none.ensure_visible = function(...)
      calls.ensure_visible = calls.ensure_visible + 1
      return real_ensure(...)
    end
  end

  -- Force the "connected" branch without a real websocket.
  local server_init = require("claudecode.server.init")
  server_init.get_status = function()
    return { running = true, client_count = 1 }
  end
  claudecode.state.server = { _fake = true }
  claudecode._broadcast_at_mention = function()
    return true, nil
  end

  claudecode.send_at_mention("/tmp/issue228.lua", 0, 5, "repro")

  -- Count only the #228 warning (by stable substring).
  local focus_warnings = 0
  for _, w in ipairs(warnings) do
    if w:find("does not focus a Claude session", 1, true) then
      focus_warnings = focus_warnings + 1
    end
  end

  return {
    name = opts.name,
    focus_warnings = focus_warnings,
    warning_text = warnings[#warnings],
    none_open_calls = calls.open,
    none_ensure_calls = calls.ensure_visible,
    active_bufnr = terminal.get_active_terminal_bufnr(),
    record = opts.record,
  }
end

-- (b) Real end-to-end check that `User ClaudeCodeSendComplete` fires on a connected
-- send, carrying the payload. Uses a fresh augroup (clear=true) because reset_modules
-- does NOT clear Neovim's global autocmd registry.
local function check_event_fires()
  reset_modules()
  local claudecode = require("claudecode")
  claudecode.setup({
    auto_start = false,
    log_level = "warn",
    track_selection = false,
    focus_after_send = true,
    terminal = { provider = "none" },
  })
  local server_init = require("claudecode.server.init")
  server_init.get_status = function()
    return { running = true, client_count = 1 }
  end
  claudecode.state.server = { _fake = true }
  claudecode._broadcast_at_mention = function(fp, s, e)
    return true, nil, { file_path = fp, start_line = s, end_line = e }
  end

  local captured = { count = 0, data = nil }
  local group = vim.api.nvim_create_augroup("Issue228EventProbe", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ClaudeCodeSendComplete",
    callback = function(ev)
      captured.count = captured.count + 1
      captured.data = ev.data
    end,
  })

  claudecode.send_at_mention("/tmp/issue228.lua", 0, 5, "repro")

  vim.api.nvim_clear_autocmds({ group = group })
  return captured
end

-- Setup-only check of the (c) warning for a given provider. Used for "external"
-- (which the run_scenario path can't exercise headlessly, since its terminal.open
-- would try to spawn). A valid external_terminal_cmd avoids the fallback-to-native
-- warning so we observe only the #228 warning.
local function setup_warning_count(provider)
  reset_modules()
  local claudecode = require("claudecode")
  local logger = require("claudecode.logger")
  local warnings = {}
  logger.warn = function(_, msg)
    if tostring(msg):find("does not focus a Claude session", 1, true) then
      table.insert(warnings, msg)
    end
  end
  claudecode.setup({
    auto_start = false,
    log_level = "warn",
    track_selection = false,
    focus_after_send = true,
    terminal = { provider = provider, provider_opts = { external_terminal_cmd = "xterm -e %s" } },
  })
  return #warnings
end

print("\n=== issue #228 fix verification: warning (c) + ClaudeCodeSendComplete event (b) ===\n")

local rec_focus = {}
local rec_nofocus = {}

local none_true = run_scenario({ name = "none / focus_after_send=true", provider = "none", focus_after_send = true })
local none_false = run_scenario({ name = "none / focus_after_send=false", provider = "none", focus_after_send = false })
local custom_true = run_scenario({
  name = "custom provider / focus_after_send=true",
  provider = recording_provider(rec_focus),
  focus_after_send = true,
  record = rec_focus,
})
local custom_false = run_scenario({
  name = "custom provider / focus_after_send=false",
  provider = recording_provider(rec_nofocus),
  focus_after_send = false,
  record = rec_nofocus,
})
local event = check_event_fires()
local external_warnings = setup_warning_count("external")

for _, r in ipairs({ none_true, none_false, custom_true, custom_false }) do
  print(("--- %s ---"):format(r.name))
  print(("  #228 setup warnings:   %d"):format(r.focus_warnings))
  if r.none_open_calls + r.none_ensure_calls > 0 then
    print(("  none.open() calls:     %d"):format(r.none_open_calls))
    print(("  none.ensure() calls:   %d"):format(r.none_ensure_calls))
  end
  if r.record then
    print(("  provider open effect:  %s"):format(tostring(r.record.open_effect == true)))
    print(("  provider show effect:  %s"):format(tostring(r.record.ensure_visible_effect == true)))
  end
  print(("  active terminal bufnr: %s"):format(tostring(r.active_bufnr)))
  print("")
end
print("--- ClaudeCodeSendComplete event ---")
print(("  fired:   %d time(s)"):format(event.count))
print(("  payload: %s"):format(vim.inspect(event.data):gsub("%s+", " ")))
print("")

local checks = {}
local function check(desc, cond)
  table.insert(checks, { desc = desc, ok = cond })
end

-- (c) The warning now fires for the inert combination, and points at the hook.
check("provider=none + focus_after_send=true emits exactly one #228 warning", none_true.focus_warnings == 1)
check(
  "the warning names focus_after_send and points at ClaudeCodeSendComplete",
  none_true.warning_text ~= nil
    and none_true.warning_text:find("focus_after_send", 1, true)
    and none_true.warning_text:find("ClaudeCodeSendComplete", 1, true)
)
check("provider=external + focus_after_send=true also warns", external_warnings == 1)
check("provider=none + focus_after_send=false stays silent", none_false.focus_warnings == 0)
-- The underlying limitation is unchanged: focus_after_send still cannot focus a
-- none terminal (no buffer is ever created); the fix is the warning + the event.
check(
  "provider=none never creates a terminal (limitation unchanged)",
  none_true.active_bufnr == nil and none_false.active_bufnr == nil
)
-- A focusable provider is unaffected: no warning, and focus_after_send still works.
check("custom (focusable) provider does NOT warn", custom_true.focus_warnings == 0 and custom_false.focus_warnings == 0)
check(
  "focus_after_send=true triggers a real provider's open(); false uses ensure_visible()",
  rec_focus.open_effect == true and rec_nofocus.ensure_visible_effect == true and rec_nofocus.open_effect ~= true
)
-- (b) The event fires exactly once per connected send, with the expected payload.
check("User ClaudeCodeSendComplete fired exactly once on a connected send", event.count == 1)
check(
  "event payload carries file_path/start_line/end_line/context",
  event.data ~= nil
    and event.data.file_path == "/tmp/issue228.lua"
    and event.data.start_line == 0
    and event.data.end_line == 5
    and event.data.context == "repro"
)

print("=== verdict ===")
local all_ok = true
for _, c in ipairs(checks) do
  print(("  [%s] %s"):format(c.ok and PASS or FAIL, c.desc))
  all_ok = all_ok and c.ok
end

print("")
if all_ok then
  print(PASS .. " issue #228 fix verified: warning fires for none/external, ClaudeCodeSendComplete fires on send.")
  vim.cmd("qa!")
else
  print(FAIL .. " fix verification failed (behaviour regressed).")
  vim.cmd("cq!")
end

require("tests.busted_setup")
require("tests.mocks.vim")

-- #228: focus_after_send is inert for providers that run Claude outside Neovim.
-- M._maybe_warn_unfocusable_provider surfaces that footgun once at setup.
describe("focus_after_send unfocusable-provider warning (#228)", function()
  local claudecode
  local warnings

  before_each(function()
    package.loaded["claudecode"] = nil
    package.loaded["claudecode.logger"] = nil
    claudecode = require("claudecode")
    -- init.lua's `logger` local references this same table, so replacing .warn
    -- here is observed by _maybe_warn_unfocusable_provider.
    local logger = require("claudecode.logger")
    warnings = {}
    logger.warn = function(_, msg)
      table.insert(warnings, tostring(msg))
    end
  end)

  after_each(function()
    package.loaded["claudecode"] = nil
    package.loaded["claudecode.logger"] = nil
  end)

  -- Count only the #228 warning, by stable substring (other warnings may exist).
  local function focus_warnings()
    local n = 0
    for _, w in ipairs(warnings) do
      if w:find("does not focus a Claude session", 1, true) then
        n = n + 1
      end
    end
    return n
  end

  it("warns for provider=none + focus_after_send=true", function()
    claudecode._maybe_warn_unfocusable_provider({ focus_after_send = true, terminal = { provider = "none" } })
    assert.is_equal(1, focus_warnings())
    assert.is_truthy(warnings[#warnings]:find("ClaudeCodeSendComplete", 1, true))
  end)

  it("warns for provider=external with a usable external_terminal_cmd (string)", function()
    claudecode._maybe_warn_unfocusable_provider({
      focus_after_send = true,
      terminal = { provider = "external", provider_opts = { external_terminal_cmd = "xterm -e %s" } },
    })
    assert.is_equal(1, focus_warnings())
    assert.is_truthy(warnings[#warnings]:find("ClaudeCodeSendComplete", 1, true))
  end)

  it("warns for provider=external with a function external_terminal_cmd", function()
    claudecode._maybe_warn_unfocusable_provider({
      focus_after_send = true,
      terminal = {
        provider = "external",
        provider_opts = {
          external_terminal_cmd = function()
            return { "xterm" }
          end,
        },
      },
    })
    assert.is_equal(1, focus_warnings())
  end)

  -- Codex P3: a misconfigured "external" (no usable command) falls back to the
  -- native provider, where focus_after_send DOES work — so it must not warn.
  it("does NOT warn for provider=external without a usable command (falls back to native)", function()
    claudecode._maybe_warn_unfocusable_provider({ focus_after_send = true, terminal = { provider = "external" } })
    assert.is_equal(0, focus_warnings())

    claudecode._maybe_warn_unfocusable_provider({
      focus_after_send = true,
      terminal = { provider = "external", provider_opts = { external_terminal_cmd = "no-placeholder" } },
    })
    assert.is_equal(0, focus_warnings())
  end)

  it("does not warn for provider=native", function()
    claudecode._maybe_warn_unfocusable_provider({ focus_after_send = true, terminal = { provider = "native" } })
    assert.is_equal(0, focus_warnings())
  end)

  it("does not warn for provider=auto (resolves to a focusable provider)", function()
    claudecode._maybe_warn_unfocusable_provider({ focus_after_send = true, terminal = { provider = "auto" } })
    assert.is_equal(0, focus_warnings())
  end)

  it("does not warn when focus_after_send=false", function()
    claudecode._maybe_warn_unfocusable_provider({ focus_after_send = false, terminal = { provider = "none" } })
    assert.is_equal(0, focus_warnings())
  end)

  it("does not warn for a custom table provider (author's responsibility)", function()
    claudecode._maybe_warn_unfocusable_provider({
      focus_after_send = true,
      terminal = {
        provider = {
          is_available = function()
            return true
          end,
        },
      },
    })
    assert.is_equal(0, focus_warnings())
  end)

  it("does not warn when terminal config is absent", function()
    claudecode._maybe_warn_unfocusable_provider({ focus_after_send = true })
    assert.is_equal(0, focus_warnings())
  end)
end)

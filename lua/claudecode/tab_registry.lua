---Tab-to-session registry for Claude Code.
---Binds each Neovim tabpage to at most one session id. Provides bidirectional
---lookup so a tab can find its session and a session can find its tab.
---@module 'claudecode.tab_registry'

local M = {}

local logger = require("claudecode.logger")

---Source-of-truth: session_id -> owning tabpage. A tab can own many sessions;
---each session belongs to exactly one tab.
---@type table<string, integer>
local session_to_tab = {}

---Per-tab "currently active" session id (last bound or switched-to). Used by
---`current_session()` for the derived active-session lookup.
---@type table<integer, string>
local tab_to_active = {}

---Look up the tab that owns a session.
---@param session_id string
---@return integer|nil tabpage
function M.tab_for_session(session_id)
  return session_to_tab[session_id]
end

---Bind (or rebind) a session to a tab and mark it active for that tab.
---Does NOT evict other sessions already owned by the tab — multiple sessions
---may share a tab.
---@param tabpage integer Neovim tabpage handle
---@param session_id string
function M.bind(tabpage, session_id)
  if not tabpage or not session_id then
    return
  end

  -- If the session previously belonged to a different tab, demote its
  -- active-session entry there.
  local prev_tab = session_to_tab[session_id]
  if prev_tab and prev_tab ~= tabpage and tab_to_active[prev_tab] == session_id then
    tab_to_active[prev_tab] = nil
  end

  session_to_tab[session_id] = tabpage
  tab_to_active[tabpage] = session_id
  logger.debug("tab_registry", "Bound tab", tabpage, "to session", session_id)
end

---Mark a session as the active one for its current tab (without changing
---ownership). Used when picker selects an existing session whose ownership
---doesn't change.
---@param session_id string
function M.set_active(session_id)
  local tab = session_to_tab[session_id]
  if tab then
    tab_to_active[tab] = session_id
  end
end

---Remove all session bindings for a tab.
---@param tabpage integer
function M.unbind_tab(tabpage)
  if not tabpage then
    return
  end
  for sid, tab in pairs(session_to_tab) do
    if tab == tabpage then
      session_to_tab[sid] = nil
    end
  end
  tab_to_active[tabpage] = nil
end

---Remove the binding for a single session.
---@param session_id string
function M.unbind_session(session_id)
  local tab = session_to_tab[session_id]
  session_to_tab[session_id] = nil
  if tab and tab_to_active[tab] == session_id then
    -- Promote any remaining session owned by this tab as the new active.
    local next_active
    for sid, owner in pairs(session_to_tab) do
      if owner == tab then
        next_active = sid
        break
      end
    end
    tab_to_active[tab] = next_active
  end
end

---List every session id owned by a tab.
---@param tabpage integer
---@return string[] session_ids
function M.sessions_for_tab(tabpage)
  local result = {}
  for sid, tab in pairs(session_to_tab) do
    if tab == tabpage then
      table.insert(result, sid)
    end
  end
  return result
end

---Active session id for a tab (the one most recently bound or marked active).
---@param tabpage integer
---@return string|nil session_id
function M.session_for_tab(tabpage)
  if not tabpage then
    return nil
  end
  local active = tab_to_active[tabpage]
  if active and session_to_tab[active] == tabpage then
    return active
  end
  -- Fallback: if the active pointer is stale, return any session owned by
  -- this tab and refresh the pointer.
  for sid, owner in pairs(session_to_tab) do
    if owner == tabpage then
      tab_to_active[tabpage] = sid
      return sid
    end
  end
  tab_to_active[tabpage] = nil
  return nil
end

---Convenience: active session for the current tabpage.
---@return string|nil session_id
function M.current_session()
  local tab = vim.api.nvim_get_current_tabpage()
  return M.session_for_tab(tab)
end

---Drop bindings for tabs that no longer exist. Returns every orphaned
---session id so callers can dispose of them.
---@return string[] orphaned_session_ids
function M.prune_invalid_tabs()
  local orphaned = {}
  for sid, tab in pairs(session_to_tab) do
    if not vim.api.nvim_tabpage_is_valid(tab) then
      table.insert(orphaned, sid)
      session_to_tab[sid] = nil
    end
  end
  for tab, _ in pairs(tab_to_active) do
    if not vim.api.nvim_tabpage_is_valid(tab) then
      tab_to_active[tab] = nil
    end
  end
  return orphaned
end

---Reset registry. For tests.
function M.reset()
  session_to_tab = {}
  tab_to_active = {}
end

---Snapshot for inspection: { tab → { active=sid, sessions={sid,...} } }.
---@return table
function M.snapshot()
  local by_tab = {}
  for sid, tab in pairs(session_to_tab) do
    by_tab[tab] = by_tab[tab] or { sessions = {} }
    table.insert(by_tab[tab].sessions, sid)
  end
  for tab, sid in pairs(tab_to_active) do
    by_tab[tab] = by_tab[tab] or { sessions = {} }
    by_tab[tab].active = sid
  end
  return by_tab
end

return M

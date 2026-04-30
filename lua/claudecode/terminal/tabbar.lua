--- Tab bar module for Claude Code terminal session switching.
--- Per-tab instances: each Neovim tabpage owns its own tabbar window/buffer
--- so rendering and click handling never leak across tabs.
--- @module 'claudecode.terminal.tabbar'

local M = {}

-- Lazy load session_manager to avoid circular dependency
local session_manager
local function get_session_manager()
  if not session_manager then
    session_manager = require("claudecode.session")
  end
  return session_manager
end

-- Lazy load tab_registry similarly
local tab_registry
local function get_tab_registry()
  if not tab_registry then
    tab_registry = require("claudecode.tab_registry")
  end
  return tab_registry
end

---@class TabBarTabState
---@field tabbar_win number|nil The tab bar floating window
---@field tabbar_buf number|nil The tab bar buffer
---@field terminal_win number|nil The terminal window we're attached to
---@field click_regions table[]    Per-tab click regions for the float
---@field winbar_session_ids table Per-tab winbar idx -> session_id

---@class TabBarModuleState
---@field tabs table<integer, TabBarTabState>  tabpage handle -> per-tab state
---@field augroup number|nil Single autocmd group (callbacks dispatch per tab)
---@field config table|nil The tabs configuration

---@type TabBarModuleState
local state = {
  tabs = {},
  augroup = nil,
  config = nil,
}

---Lazily create and return the per-tab state slot.
---@param tabpage integer
---@return TabBarTabState
local function get_tab_state(tabpage)
  local slot = state.tabs[tabpage]
  if not slot then
    slot = {
      tabbar_win = nil,
      tabbar_buf = nil,
      terminal_win = nil,
      click_regions = {},
      winbar_session_ids = {},
    }
    state.tabs[tabpage] = slot
  end
  return slot
end

---Resolve a tabpage handle: explicit arg wins, else current tab.
---@param tabpage integer|nil
---@return integer|nil
local function resolve_tab(tabpage)
  if tabpage then
    return tabpage
  end
  local ok, t = pcall(vim.api.nvim_get_current_tabpage)
  if ok then
    return t
  end
  return nil
end

---List sessions owned by a specific tabpage. Strictly tab-scoped.
---@param tabpage integer
---@return ClaudeCodeSession[]
local function list_sessions_for(tabpage)
  local sm = get_session_manager()
  local reg = get_tab_registry()
  local result = {}
  for _, session in ipairs(sm.list_sessions()) do
    if reg.tab_for_session(session.id) == tabpage then
      table.insert(result, session)
    end
  end
  return result
end

-- ============================================================================
-- Highlight Groups
-- ============================================================================

local function setup_highlights()
  if not vim.api.nvim_set_hl then
    return
  end

  local hl = vim.api.nvim_set_hl
  hl(0, "ClaudeCodeTabBar", { link = "StatusLine", default = true })
  hl(0, "ClaudeCodeTabActive", { link = "TabLineSel", default = true })
  hl(0, "ClaudeCodeTabInactive", { link = "TabLine", default = true })
  hl(0, "ClaudeCodeTabNew", { link = "Special", default = true })
  hl(0, "ClaudeCodeTabClose", { link = "Error", default = true })
end

-- ============================================================================
-- Tab Bar Content (float)
-- ============================================================================

---Build the tab bar content line for a given tabpage. Populates the per-tab
---click_regions array.
---@param tabpage integer
---@return string content, table highlights
local function build_content(tabpage)
  local slot = get_tab_state(tabpage)
  local sessions = list_sessions_for(tabpage)
  local active_id = get_tab_registry().session_for_tab(tabpage)

  slot.click_regions = {}

  if #sessions == 0 then
    return " Claude Code ", {}
  end

  local parts = {}
  local highlights = {}
  local col = 1

  for i, session in ipairs(sessions) do
    local is_active = session.id == active_id
    local name = session.name or ("Session " .. i)
    if #name > 12 then
      name = name:sub(1, 9) .. "..."
    end

    local label = string.format(" %d:%s ", i, name)
    local hl_group = is_active and "ClaudeCodeTabActive" or "ClaudeCodeTabInactive"

    table.insert(slot.click_regions, {
      start_col = col,
      end_col = col + #label - 1,
      action = "switch",
      session_id = session.id,
    })
    table.insert(highlights, { col - 1, col - 1 + #label, hl_group })
    table.insert(parts, label)
    col = col + #label

    if state.config and state.config.show_close_button then
      local close_btn = "✕ "
      table.insert(slot.click_regions, {
        start_col = col,
        end_col = col + #close_btn - 1,
        action = "close",
        session_id = session.id,
      })
      table.insert(highlights, { col - 1, col - 1 + #close_btn, hl_group })
      table.insert(parts, close_btn)
      col = col + #close_btn
    end

    if i < #sessions then
      table.insert(parts, "|")
      col = col + 1
    end
  end

  if state.config and state.config.show_new_button then
    local new_btn = " + "
    table.insert(slot.click_regions, {
      start_col = col,
      end_col = col + #new_btn - 1,
      action = "new",
    })
    table.insert(parts, new_btn)
    table.insert(highlights, { col - 1, col - 1 + #new_btn, "ClaudeCodeTabNew" })
  end

  return table.concat(parts), highlights
end

-- ============================================================================
-- Per-tab mouse handlers (buffer-local mappings)
-- ============================================================================

---Resolve column under the mouse, scoped to the tabbar window.
---@param tabpage integer
---@return integer|nil col
local function mouse_col_in_tabbar(tabpage)
  local slot = state.tabs[tabpage]
  if not slot or not slot.tabbar_win or not vim.api.nvim_win_is_valid(slot.tabbar_win) then
    return nil
  end
  if not vim.fn.getmousepos then
    return nil
  end
  local mouse = vim.fn.getmousepos()
  if not mouse or mouse.winid ~= slot.tabbar_win then
    return nil
  end
  return mouse.wincol or mouse.column or 1
end

---Refocus the terminal window after a click on the tabbar so the user can
---type into Claude immediately.
---@param tabpage integer
local function refocus_terminal(tabpage)
  local slot = state.tabs[tabpage]
  if slot and slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
    pcall(vim.api.nvim_set_current_win, slot.terminal_win)
  end
end

---Dispatch a left click on the tabbar.
---@param tabpage integer
local function handle_left_click(tabpage)
  local col = mouse_col_in_tabbar(tabpage)
  if not col then
    return
  end
  local slot = state.tabs[tabpage]
  for _, region in ipairs(slot.click_regions) do
    if col >= region.start_col and col <= region.end_col then
      if region.action == "switch" and region.session_id then
        local sid = region.session_id
        vim.schedule(function()
          require("claudecode.terminal").switch_to_session(sid)
          refocus_terminal(tabpage)
        end)
      elseif region.action == "close" and region.session_id then
        local sid = region.session_id
        vim.schedule(function()
          require("claudecode.terminal").close_session(sid)
        end)
      elseif region.action == "new" then
        vim.schedule(function()
          require("claudecode.terminal").open_new_session()
          refocus_terminal(tabpage)
        end)
      end
      return
    end
  end
end

---Dispatch a middle click — close the session whose region was hit.
---@param tabpage integer
local function handle_middle_click(tabpage)
  local col = mouse_col_in_tabbar(tabpage)
  if not col then
    return
  end
  local slot = state.tabs[tabpage]
  for _, region in ipairs(slot.click_regions) do
    if col >= region.start_col and col <= region.end_col then
      if region.session_id then
        local sid = region.session_id
        vim.schedule(function()
          require("claudecode.terminal").close_session(sid)
        end)
      end
      return
    end
  end
end

---Cycle through sessions on the wheel.
---@param tabpage integer
---@param direction "up"|"down"
local function handle_scroll(tabpage, direction)
  local sessions = list_sessions_for(tabpage)
  if #sessions <= 1 then
    return
  end
  local active_id = get_tab_registry().session_for_tab(tabpage)
  for i, session in ipairs(sessions) do
    if session.id == active_id then
      local next_idx
      if direction == "up" then
        next_idx = ((i - 2) % #sessions) + 1
      else
        next_idx = (i % #sessions) + 1
      end
      local target = sessions[next_idx].id
      vim.schedule(function()
        require("claudecode.terminal").switch_to_session(target)
        refocus_terminal(tabpage)
      end)
      return
    end
  end
end

---Bind buffer-local mouse mappings on the tabbar buffer for a tab.
---@param tabpage integer
---@param buf integer
local function setup_buffer_mappings(tabpage, buf)
  local map = function(lhs, fn)
    vim.keymap.set({ "n", "i" }, lhs, function()
      fn(tabpage)
    end, { buffer = buf, nowait = true, silent = true })
  end
  map("<LeftMouse>", handle_left_click)
  map("<MiddleMouse>", handle_middle_click)
  vim.keymap.set({ "n", "i" }, "<ScrollWheelUp>", function()
    handle_scroll(tabpage, "up")
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<ScrollWheelDown>", function()
    handle_scroll(tabpage, "down")
  end, { buffer = buf, nowait = true, silent = true })
end

-- ============================================================================
-- Tab Bar Window Management
-- ============================================================================

---Create or reuse the per-tab tabbar buffer.
---@param tabpage integer
---@return integer bufnr
local function ensure_buffer(tabpage)
  local slot = get_tab_state(tabpage)
  if slot.tabbar_buf and vim.api.nvim_buf_is_valid(slot.tabbar_buf) then
    return slot.tabbar_buf
  end

  slot.tabbar_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[slot.tabbar_buf].buftype = "nofile"
  vim.bo[slot.tabbar_buf].bufhidden = "hide"
  vim.bo[slot.tabbar_buf].swapfile = false
  vim.bo[slot.tabbar_buf].modifiable = true

  setup_buffer_mappings(tabpage, slot.tabbar_buf)

  return slot.tabbar_buf
end

---Compute the float window config for the tabbar.
---@param term_win number
---@return table|nil
local function calc_window_config(term_win)
  if not term_win or not vim.api.nvim_win_is_valid(term_win) then
    return nil
  end
  local term_config = vim.api.nvim_win_get_config(term_win)
  local term_pos = vim.api.nvim_win_get_position(term_win)
  local term_width = vim.api.nvim_win_get_width(term_win)

  if term_config.relative and term_config.relative ~= "" then
    return {
      relative = "editor",
      row = term_pos[1],
      col = term_pos[2],
      width = term_width,
      height = 1,
      style = "minimal",
      border = "none",
      zindex = (term_config.zindex or 50) + 1,
      focusable = false, -- click via buffer-local <LeftMouse> map; no focus theft
    }
  end
  -- Splits use the winbar fallback path
  return nil
end

---Show the tabbar for a tab.
---@param tabpage integer|nil
function M.show(tabpage)
  if not state.config or not state.config.enabled then
    return
  end
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return
  end
  local slot = get_tab_state(tabpage)
  if not slot.terminal_win or not vim.api.nvim_win_is_valid(slot.terminal_win) then
    return
  end

  local win_config = calc_window_config(slot.terminal_win)
  if not win_config then
    M.render_winbar(tabpage)
    return
  end

  ensure_buffer(tabpage)

  if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
    vim.api.nvim_win_set_config(slot.tabbar_win, win_config)
  else
    slot.tabbar_win = vim.api.nvim_open_win(slot.tabbar_buf, false, win_config)
    vim.api.nvim_win_set_option(slot.tabbar_win, "winhl", "Normal:ClaudeCodeTabBar")
  end

  M.render(tabpage)
end

---Hide the tabbar for a tab.
---@param tabpage integer|nil
function M.hide(tabpage)
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return
  end
  local slot = state.tabs[tabpage]
  if not slot then
    return
  end
  if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
    pcall(vim.api.nvim_win_close, slot.tabbar_win, true)
  end
  slot.tabbar_win = nil
  if slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
    pcall(function()
      vim.wo[slot.terminal_win].winbar = nil
    end)
  end
end

---Render tab bar content for a tab.
---@param tabpage integer|nil
function M.render(tabpage)
  if not state.config or not state.config.enabled then
    return
  end
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return
  end
  local slot = state.tabs[tabpage]
  if not slot then
    return
  end

  local content, highlights = build_content(tabpage)

  if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
    if slot.tabbar_buf and vim.api.nvim_buf_is_valid(slot.tabbar_buf) then
      vim.api.nvim_buf_set_lines(slot.tabbar_buf, 0, -1, false, { content })

      local ns = vim.api.nvim_create_namespace("claudecode_tabbar")
      vim.api.nvim_buf_clear_namespace(slot.tabbar_buf, ns, 0, -1)
      for _, hl in ipairs(highlights) do
        pcall(vim.api.nvim_buf_add_highlight, slot.tabbar_buf, ns, hl[3], 0, hl[1], hl[2])
      end
    end

    if slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
      local win_config = calc_window_config(slot.terminal_win)
      if win_config then
        pcall(vim.api.nvim_win_set_config, slot.tabbar_win, win_config)
      end
    end
  else
    M.render_winbar(tabpage)
  end
end

-- ============================================================================
-- Winbar fallback (split windows)
-- ============================================================================

---Look up the winbar session id for an index in the *current* tabpage. Called
---from `%@FuncName@` click handlers below, where the dispatch only carries the
---index. The user clicks winbar in their focused tab, so reading the current
---tab is correct.
---@param idx integer
---@return string|nil
local function current_tab_winbar_session(idx)
  local ok, tab = pcall(vim.api.nvim_get_current_tabpage)
  if not ok or not tab then
    return nil
  end
  local slot = state.tabs[tab]
  if not slot then
    return nil
  end
  return slot.winbar_session_ids[idx]
end

function _G.ClaudeCodeTabClick(session_idx, _, button, _)
  local session_id = current_tab_winbar_session(session_idx)
  if not session_id then
    return
  end
  vim.schedule(function()
    if button == "l" then
      require("claudecode.terminal").switch_to_session(session_id)
    elseif button == "m" then
      require("claudecode.terminal").close_session(session_id)
    end
  end)
end

function _G.ClaudeCodeCloseTabClick(session_idx, _, button, _)
  if button ~= "l" then
    return
  end
  local session_id = current_tab_winbar_session(session_idx)
  if not session_id then
    return
  end
  vim.schedule(function()
    require("claudecode.terminal").close_session(session_id)
  end)
end

function _G.ClaudeCodeNewTabClick(_, _, button, _)
  if button == "l" then
    vim.schedule(function()
      require("claudecode.terminal").open_new_session()
    end)
  end
end

---Render the tabbar as a winbar on the terminal window (split mode).
---@param tabpage integer|nil
function M.render_winbar(tabpage)
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return
  end
  local slot = state.tabs[tabpage]
  if not slot or not slot.terminal_win or not vim.api.nvim_win_is_valid(slot.terminal_win) then
    return
  end

  local sessions = list_sessions_for(tabpage)
  local active_id = get_tab_registry().session_for_tab(tabpage)
  if #sessions == 0 then
    return
  end

  slot.winbar_session_ids = {}

  local parts = {}
  for i, session in ipairs(sessions) do
    local is_active = session.id == active_id
    local name = session.name or ("Session " .. i)
    if #name > 12 then
      name = name:sub(1, 9) .. "..."
    end

    slot.winbar_session_ids[i] = session.id

    local hl = is_active and "%#ClaudeCodeTabActive#" or "%#ClaudeCodeTabInactive#"
    local click_start = string.format("%%%d@v:lua.ClaudeCodeTabClick@", i)
    local click_end = "%X"

    local tab_content = hl .. " " .. i .. ":" .. name .. " "

    if state.config and state.config.show_close_button then
      local close_click = string.format("%%%d@v:lua.ClaudeCodeCloseTabClick@", i)
      tab_content = tab_content .. click_end .. close_click .. hl .. "✕%X "
    end

    table.insert(parts, click_start .. tab_content .. click_end)
  end

  if state.config and state.config.show_new_button then
    local click_start = "%0@v:lua.ClaudeCodeNewTabClick@"
    local click_end = "%X"
    table.insert(parts, click_start .. "%#ClaudeCodeTabNew# + " .. click_end)
  end

  local winbar = table.concat(parts, "%#StatusLine#|") .. "%#Normal#"
  pcall(function()
    vim.wo[slot.terminal_win].winbar = winbar
  end)
end

-- ============================================================================
-- Keyboard navigation
-- ============================================================================

---Setup keymaps on the terminal buffer for session switching.
---@param bufnr integer
function M.setup_keymaps(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local keymaps = state.config and state.config.keymaps or {}

  local terminal_mod = function()
    return require("claudecode.terminal")
  end

  local tab_for_active = function()
    local ok, t = pcall(vim.api.nvim_get_current_tabpage)
    if ok then
      return t
    end
    return nil
  end

  if keymaps.next_tab then
    vim.keymap.set({ "n", "t" }, keymaps.next_tab, function()
      local tab = tab_for_active()
      if not tab then
        return
      end
      local sessions = list_sessions_for(tab)
      if #sessions <= 1 then
        return
      end
      local active_id = get_tab_registry().session_for_tab(tab)
      for i, session in ipairs(sessions) do
        if session.id == active_id then
          local next_idx = (i % #sessions) + 1
          terminal_mod().switch_to_session(sessions[next_idx].id)
          return
        end
      end
    end, { buffer = bufnr, desc = "Next Claude session" })
  end

  if keymaps.prev_tab then
    vim.keymap.set({ "n", "t" }, keymaps.prev_tab, function()
      local tab = tab_for_active()
      if not tab then
        return
      end
      local sessions = list_sessions_for(tab)
      if #sessions <= 1 then
        return
      end
      local active_id = get_tab_registry().session_for_tab(tab)
      for i, session in ipairs(sessions) do
        if session.id == active_id then
          local prev_idx = ((i - 2) % #sessions) + 1
          terminal_mod().switch_to_session(sessions[prev_idx].id)
          return
        end
      end
    end, { buffer = bufnr, desc = "Previous Claude session" })
  end

  if keymaps.new_tab then
    vim.keymap.set({ "n", "t" }, keymaps.new_tab, function()
      terminal_mod().open_new_session()
    end, { buffer = bufnr, desc = "New Claude session" })
  end

  if keymaps.close_tab then
    vim.keymap.set({ "n", "t" }, keymaps.close_tab, function()
      local tab = tab_for_active()
      if not tab then
        return
      end
      local active_id = get_tab_registry().session_for_tab(tab)
      if active_id then
        terminal_mod().close_session(active_id)
      end
    end, { buffer = bufnr, desc = "Close Claude session" })
  end
end

-- ============================================================================
-- Autocmds
-- ============================================================================

---Iterate every active per-tab slot, calling fn(tab, slot). Skips tabs whose
---tabpage handle is no longer valid (and drops their slot).
---@param fn fun(tab: integer, slot: TabBarTabState)
local function for_each_tab(fn)
  for tab, slot in pairs(state.tabs) do
    if not vim.api.nvim_tabpage_is_valid(tab) then
      state.tabs[tab] = nil
    else
      fn(tab, slot)
    end
  end
end

---Find the tab whose slot owns a particular terminal window.
---@param winid integer
---@return integer|nil tab
local function tab_for_terminal_win(winid)
  for tab, slot in pairs(state.tabs) do
    if slot.terminal_win == winid then
      return tab
    end
  end
  return nil
end

local function setup_autocmds()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  state.augroup = vim.api.nvim_create_augroup("ClaudeCodeTabBar", { clear = true })

  -- Re-position float / re-render winbar when geometry changes.
  vim.api.nvim_create_autocmd({ "WinResized", "WinScrolled" }, {
    group = state.augroup,
    callback = function()
      for_each_tab(function(tab, slot)
        if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
          M.show(tab)
        elseif slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
          M.render_winbar(tab)
        end
      end)
    end,
  })

  -- Session-state events touch every tab's tabbar so the active indicator and
  -- session list stay correct.
  vim.api.nvim_create_autocmd("User", {
    group = state.augroup,
    pattern = { "ClaudeCodeSessionCreated", "ClaudeCodeSessionDestroyed", "ClaudeCodeSessionNameChanged" },
    callback = function()
      for_each_tab(function(tab, slot)
        if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
          M.render(tab)
        elseif slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
          M.render_winbar(tab)
        end
      end)
    end,
  })

  -- Terminal window closed → clear that tab's tabbar slot.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    callback = function(args)
      local win = tonumber(args.match)
      if not win then
        return
      end
      local tab = tab_for_terminal_win(win)
      if tab then
        M.hide(tab)
        state.tabs[tab].terminal_win = nil
      end
    end,
  })

  -- Tab closed → drop the slot entirely.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = state.augroup,
    callback = function()
      for tab, _ in pairs(state.tabs) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
          state.tabs[tab] = nil
        end
      end
    end,
  })

  -- Tab entered → if the tab owns a session whose terminal window is still
  -- visible but the tabbar slot lost its float (e.g. user manually `:close`d
  -- it, or the slot was never created), re-attach so the user sees a tabbar
  -- in this tab without having to toggle the terminal.
  vim.api.nvim_create_autocmd("TabEnter", {
    group = state.augroup,
    callback = function()
      local ok, tab = pcall(vim.api.nvim_get_current_tabpage)
      if not ok or not tab then
        return
      end
      local sid = get_tab_registry().session_for_tab(tab)
      if not sid then
        return
      end
      local sess = get_session_manager().get_session(sid)
      if not sess or not sess.terminal_bufnr or not vim.api.nvim_buf_is_valid(sess.terminal_bufnr) then
        return
      end
      -- Find a window in this tab that displays the terminal buffer.
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == sess.terminal_bufnr then
          local slot = get_tab_state(tab)
          if not slot.tabbar_win or not vim.api.nvim_win_is_valid(slot.tabbar_win) then
            slot.terminal_win = w
            M.show(tab)
          end
          return
        end
      end
    end,
  })
end

-- ============================================================================
-- Public API
-- ============================================================================

---Initialize the tab bar module.
---@param config table Tabs configuration
function M.setup(config)
  state.config = config
  setup_highlights()
  if config and config.enabled then
    setup_autocmds()
  end
end

---Attach the tabbar to a terminal window. The tab is resolved from the
---window's tabpage so callers don't need to pass it.
---@param terminal_win integer Terminal window ID
---@param terminal_bufnr integer|nil Terminal buffer (for keymaps)
---@param _ any Unused (kept for API compatibility)
function M.attach(terminal_win, terminal_bufnr, _)
  if not state.config or not state.config.enabled then
    return
  end
  if not terminal_win or not vim.api.nvim_win_is_valid(terminal_win) then
    return
  end
  local ok, tab = pcall(vim.api.nvim_win_get_tabpage, terminal_win)
  if not ok or not tab then
    return
  end

  local slot = get_tab_state(tab)
  slot.terminal_win = terminal_win

  if terminal_bufnr then
    M.setup_keymaps(terminal_bufnr)
  end

  M.show(tab)
end

---Detach the tabbar from a tab. Defaults to the current tab.
---@param tabpage integer|nil
function M.detach(tabpage)
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return
  end
  M.hide(tabpage)
  local slot = state.tabs[tabpage]
  if slot then
    slot.terminal_win = nil
  end
end

---Whether the tabbar is visible in the current tab.
---@return boolean
function M.is_visible()
  local ok, tab = pcall(vim.api.nvim_get_current_tabpage)
  if not ok then
    return false
  end
  local slot = state.tabs[tab]
  if not slot then
    return false
  end
  if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
    return true
  end
  if slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
    return vim.wo[slot.terminal_win].winbar ~= ""
  end
  return false
end

---Get the tabbar window id for the current tab (nil if none).
---@return integer|nil
function M.get_winid()
  local ok, tab = pcall(vim.api.nvim_get_current_tabpage)
  if not ok then
    return nil
  end
  local slot = state.tabs[tab]
  if slot and slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
    return slot.tabbar_win
  end
  return nil
end

---Cleanup state for one tab (or current tab if omitted).
---@param tabpage integer|nil
function M.cleanup(tabpage)
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return
  end
  M.hide(tabpage)
  local slot = state.tabs[tabpage]
  if slot and slot.tabbar_buf and vim.api.nvim_buf_is_valid(slot.tabbar_buf) then
    pcall(vim.api.nvim_buf_delete, slot.tabbar_buf, { force = true })
  end
  state.tabs[tabpage] = nil
end

---Cleanup every tab's tabbar (plugin reload / VimLeavePre).
function M.cleanup_all()
  for tab, _ in pairs(state.tabs) do
    M.cleanup(tab)
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
end

---Snapshot of per-tab state for tests / debugging.
---@return table<integer, TabBarTabState>
function M._snapshot()
  local out = {}
  for tab, slot in pairs(state.tabs) do
    out[tab] = {
      tabbar_win = slot.tabbar_win,
      tabbar_buf = slot.tabbar_buf,
      terminal_win = slot.terminal_win,
      click_regions = vim.deepcopy(slot.click_regions),
      winbar_session_ids = vim.deepcopy(slot.winbar_session_ids),
    }
  end
  return out
end

---Reset module state (tests).
function M._reset()
  for tab, _ in pairs(state.tabs) do
    state.tabs[tab] = nil
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  state.config = nil
end

return M

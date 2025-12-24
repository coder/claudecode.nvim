--- Tab bar module for Claude Code terminal session switching.
--- Creates a separate floating window for session tabs.
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

---@class TabBarState
---@field tabbar_win number|nil The tab bar floating window
---@field tabbar_buf number|nil The tab bar buffer
---@field terminal_win number|nil The terminal window we're attached to
---@field augroup number|nil The autocmd group
---@field config table The tabs configuration

---@type TabBarState
local state = {
  tabbar_win = nil,
  tabbar_buf = nil,
  terminal_win = nil,
  augroup = nil,
  config = nil,
}

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
-- Tab Bar Content
-- ============================================================================

-- Track click regions for mouse support
local click_regions = {} -- Array of {start_col, end_col, action, session_id}

---Handle mouse click at given column
---@param col number Column position (1-indexed)
local function handle_click(col)
  for _, region in ipairs(click_regions) do
    if col >= region.start_col and col <= region.end_col then
      if region.action == "switch" and region.session_id then
        vim.schedule(function()
          require("claudecode.terminal").switch_to_session(region.session_id)
        end)
      elseif region.action == "close" and region.session_id then
        vim.schedule(function()
          require("claudecode.terminal").close_session(region.session_id)
        end)
      elseif region.action == "new" then
        vim.schedule(function()
          require("claudecode.terminal").open_new_session()
        end)
      end
      return true
    end
  end
  return false
end

---Build the tab bar content line
---@return string content The tab bar content
---@return table highlights Array of {col_start, col_end, hl_group}
local function build_content()
  local sessions = get_session_manager().list_sessions()
  local active_id = get_session_manager().get_active_session_id()

  -- Reset click regions
  click_regions = {}

  if #sessions == 0 then
    return " Claude Code ", {}
  end

  local parts = {}
  local highlights = {}
  local col = 1 -- 1-indexed column position

  for i, session in ipairs(sessions) do
    local is_active = session.id == active_id
    local name = session.name or ("Session " .. i)
    if #name > 12 then
      name = name:sub(1, 9) .. "..."
    end

    local label = string.format(" %d:%s ", i, name)
    local hl_group = is_active and "ClaudeCodeTabActive" or "ClaudeCodeTabInactive"

    -- Track click region for this tab
    table.insert(click_regions, {
      start_col = col,
      end_col = col + #label - 1,
      action = "switch",
      session_id = session.id,
    })

    table.insert(highlights, { col - 1, col - 1 + #label, hl_group })
    table.insert(parts, label)
    col = col + #label

    -- Add close button if enabled
    if state.config and state.config.show_close_button then
      local close_btn = "✕ "
      table.insert(click_regions, {
        start_col = col,
        end_col = col + #close_btn - 1,
        action = "close",
        session_id = session.id,
      })
      -- Use same highlight as tab for consistent background
      table.insert(highlights, { col - 1, col - 1 + #close_btn, hl_group })
      table.insert(parts, close_btn)
      col = col + #close_btn
    end

    if i < #sessions then
      table.insert(parts, "|")
      col = col + 1
    end
  end

  -- Add new session button
  if state.config and state.config.show_new_button then
    local new_btn = " + "
    table.insert(click_regions, {
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
-- Tab Bar Window Management
-- ============================================================================

---Check if a mouse click is in the tabbar window and handle it
---@return boolean handled True if click was handled
local function check_and_handle_tabbar_click()
  if not state.tabbar_win or not vim.api.nvim_win_is_valid(state.tabbar_win) then
    return false
  end

  local mouse = vim.fn.getmousepos()
  if not mouse or mouse.winid ~= state.tabbar_win then
    return false
  end

  local col = mouse.wincol or mouse.column or 1
  return handle_click(col)
end

---Create or update the tab bar buffer
local function ensure_buffer()
  if state.tabbar_buf and vim.api.nvim_buf_is_valid(state.tabbar_buf) then
    return state.tabbar_buf
  end

  state.tabbar_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.tabbar_buf].buftype = "nofile"
  vim.bo[state.tabbar_buf].bufhidden = "hide"
  vim.bo[state.tabbar_buf].swapfile = false
  vim.bo[state.tabbar_buf].modifiable = true

  return state.tabbar_buf
end

---Handle middle click to close session
---@param col number Column position (1-indexed)
---@return boolean handled True if click was handled
local function handle_middle_click(col)
  for _, region in ipairs(click_regions) do
    if col >= region.start_col and col <= region.end_col then
      if region.action == "switch" and region.session_id then
        vim.schedule(function()
          require("claudecode.terminal").close_session(region.session_id)
        end)
        return true
      end
    end
  end
  return false
end

---Handle scroll wheel to cycle sessions
---@param direction string "up" or "down"
local function handle_scroll(direction)
  local sessions = get_session_manager().list_sessions()
  local active_id = get_session_manager().get_active_session_id()

  if #sessions <= 1 then
    return
  end

  for i, session in ipairs(sessions) do
    if session.id == active_id then
      local next_idx
      if direction == "up" then
        next_idx = ((i - 2) % #sessions) + 1 -- Previous
      else
        next_idx = (i % #sessions) + 1 -- Next
      end
      vim.schedule(function()
        require("claudecode.terminal").switch_to_session(sessions[next_idx].id)
      end)
      return
    end
  end
end

---Check if scroll is in tabbar and handle it
---@param direction string "up" or "down"
---@return boolean handled True if scroll was handled
local function check_and_handle_tabbar_scroll(direction)
  if not state.tabbar_win or not vim.api.nvim_win_is_valid(state.tabbar_win) then
    return false
  end

  local mouse = vim.fn.getmousepos()
  if not mouse or mouse.winid ~= state.tabbar_win then
    return false
  end

  handle_scroll(direction)
  return true
end

---Check if middle click is in tabbar and handle it
---@return boolean handled True if click was handled
local function check_and_handle_tabbar_middle_click()
  if not state.tabbar_win or not vim.api.nvim_win_is_valid(state.tabbar_win) then
    return false
  end

  local mouse = vim.fn.getmousepos()
  if not mouse or mouse.winid ~= state.tabbar_win then
    return false
  end

  local col = mouse.wincol or mouse.column or 1
  return handle_middle_click(col)
end

---Setup global mouse click handler
local mouse_handler_set = false
local function setup_mouse_handler()
  if mouse_handler_set then
    return
  end
  mouse_handler_set = true

  -- Cache termcodes for mouse events
  local left_mouse = vim.api.nvim_replace_termcodes("<LeftMouse>", true, false, true)
  local left_release = vim.api.nvim_replace_termcodes("<LeftRelease>", true, false, true)
  local middle_mouse = vim.api.nvim_replace_termcodes("<MiddleMouse>", true, false, true)
  local middle_release = vim.api.nvim_replace_termcodes("<MiddleRelease>", true, false, true)
  local scroll_up = vim.api.nvim_replace_termcodes("<ScrollWheelUp>", true, false, true)
  local scroll_down = vim.api.nvim_replace_termcodes("<ScrollWheelDown>", true, false, true)

  -- Global mouse handler that checks if click is in tabbar
  vim.on_key(function(key)
    if key == left_mouse or key == left_release then
      vim.schedule(function()
        check_and_handle_tabbar_click()
      end)
    elseif key == middle_mouse or key == middle_release then
      vim.schedule(function()
        check_and_handle_tabbar_middle_click()
      end)
    elseif key == scroll_up then
      vim.schedule(function()
        check_and_handle_tabbar_scroll("up")
      end)
    elseif key == scroll_down then
      vim.schedule(function()
        check_and_handle_tabbar_scroll("down")
      end)
    end
  end)
end

---Calculate position for tab bar window (above terminal)
---@param term_win number Terminal window ID
---@return table|nil config Window config or nil if invalid
local function calc_window_config(term_win)
  if not term_win or not vim.api.nvim_win_is_valid(term_win) then
    return nil
  end

  local term_config = vim.api.nvim_win_get_config(term_win)
  local term_pos = vim.api.nvim_win_get_position(term_win)
  local term_width = vim.api.nvim_win_get_width(term_win)

  -- For floating windows
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
      focusable = true, -- Allow clicks
    }
  end

  -- For split windows, use winbar instead (handled separately)
  return nil
end

---Show the tab bar window
function M.show()
  if not state.config or not state.config.enabled then
    return
  end

  if not state.terminal_win or not vim.api.nvim_win_is_valid(state.terminal_win) then
    return
  end

  local win_config = calc_window_config(state.terminal_win)

  if not win_config then
    -- Fallback to winbar for split windows
    M.render_winbar()
    return
  end

  ensure_buffer()

  -- Create or update window
  if state.tabbar_win and vim.api.nvim_win_is_valid(state.tabbar_win) then
    vim.api.nvim_win_set_config(state.tabbar_win, win_config)
  else
    state.tabbar_win = vim.api.nvim_open_win(state.tabbar_buf, false, win_config)
    vim.api.nvim_win_set_option(state.tabbar_win, "winhl", "Normal:ClaudeCodeTabBar")
  end

  M.render()
end

---Hide the tab bar window
function M.hide()
  if state.tabbar_win and vim.api.nvim_win_is_valid(state.tabbar_win) then
    vim.api.nvim_win_close(state.tabbar_win, true)
  end
  state.tabbar_win = nil

  -- Also clear winbar
  if state.terminal_win and vim.api.nvim_win_is_valid(state.terminal_win) then
    pcall(function()
      vim.wo[state.terminal_win].winbar = nil
    end)
  end
end

---Render tab bar content
function M.render()
  if not state.config or not state.config.enabled then
    return
  end

  local content, highlights = build_content()

  -- Update floating window if exists
  if state.tabbar_win and vim.api.nvim_win_is_valid(state.tabbar_win) then
    if state.tabbar_buf and vim.api.nvim_buf_is_valid(state.tabbar_buf) then
      vim.api.nvim_buf_set_lines(state.tabbar_buf, 0, -1, false, { content })

      -- Apply highlights
      local ns = vim.api.nvim_create_namespace("claudecode_tabbar")
      vim.api.nvim_buf_clear_namespace(state.tabbar_buf, ns, 0, -1)
      for _, hl in ipairs(highlights) do
        pcall(vim.api.nvim_buf_add_highlight, state.tabbar_buf, ns, hl[3], 0, hl[1], hl[2])
      end
    end

    -- Update window position in case terminal moved
    local win_config = calc_window_config(state.terminal_win)
    if win_config then
      pcall(vim.api.nvim_win_set_config, state.tabbar_win, win_config)
    end
  else
    -- Try winbar fallback
    M.render_winbar()
  end
end

-- Store session IDs for winbar click handlers (indexed by position)
local winbar_session_ids = {}

---Global click handler for winbar session tabs
---@param session_idx number The 1-indexed session position
---@param clicks number Number of clicks
---@param button string Mouse button ("l", "m", "r")
---@param mods string Modifiers
function _G.ClaudeCodeTabClick(session_idx, clicks, button, mods)
  local session_id = winbar_session_ids[session_idx]
  if not session_id then
    return
  end

  vim.schedule(function()
    if button == "l" then
      -- Left click: switch to session
      require("claudecode.terminal").switch_to_session(session_id)
    elseif button == "m" then
      -- Middle click: close session
      require("claudecode.terminal").close_session(session_id)
    end
  end)
end

---Global click handler for winbar close button
---@param session_idx number The 1-indexed session position
---@param clicks number Number of clicks
---@param button string Mouse button ("l", "m", "r")
---@param mods string Modifiers
function _G.ClaudeCodeCloseTabClick(session_idx, clicks, button, mods)
  local session_id = winbar_session_ids[session_idx]
  if not session_id then
    return
  end

  if button == "l" then
    vim.schedule(function()
      require("claudecode.terminal").close_session(session_id)
    end)
  end
end

---Global click handler for winbar new session button
---@param _ number Unused
---@param clicks number Number of clicks
---@param button string Mouse button
---@param mods string Modifiers
function _G.ClaudeCodeNewTabClick(_, clicks, button, mods)
  if button == "l" then
    vim.schedule(function()
      require("claudecode.terminal").open_new_session()
    end)
  end
end

---Render to winbar (for split windows)
function M.render_winbar()
  if not state.terminal_win or not vim.api.nvim_win_is_valid(state.terminal_win) then
    return
  end

  local sessions = get_session_manager().list_sessions()
  local active_id = get_session_manager().get_active_session_id()

  if #sessions == 0 then
    return
  end

  -- Reset session ID mapping
  winbar_session_ids = {}

  local parts = {}
  for i, session in ipairs(sessions) do
    local is_active = session.id == active_id
    local name = session.name or ("Session " .. i)
    if #name > 12 then
      name = name:sub(1, 9) .. "..."
    end

    -- Store session ID for click handler
    winbar_session_ids[i] = session.id

    local hl = is_active and "%#ClaudeCodeTabActive#" or "%#ClaudeCodeTabInactive#"
    -- Use %@FuncName@ syntax for clickable regions
    -- %<nr>@FuncName@ calls FuncName(nr, clicks, button, mods)
    local click_start = string.format("%%%d@v:lua.ClaudeCodeTabClick@", i)
    local click_end = "%X"

    -- Build tab content with optional close button
    local tab_content = hl .. " " .. i .. ":" .. name .. " "

    if state.config and state.config.show_close_button then
      local close_click = string.format("%%%d@v:lua.ClaudeCodeCloseTabClick@", i)
      -- Keep same highlight as tab for consistent background
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
    vim.wo[state.terminal_win].winbar = winbar
  end)
end

-- ============================================================================
-- Keyboard Navigation
-- ============================================================================

---Setup keymaps for session switching
---@param bufnr number Buffer number
function M.setup_keymaps(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local keymaps = state.config and state.config.keymaps or {}

  if keymaps.next_tab then
    vim.keymap.set({ "n", "t" }, keymaps.next_tab, function()
      local sessions = get_session_manager().list_sessions()
      local active_id = get_session_manager().get_active_session_id()
      if #sessions <= 1 then
        return
      end
      for i, session in ipairs(sessions) do
        if session.id == active_id then
          local next_idx = (i % #sessions) + 1
          require("claudecode.terminal").switch_to_session(sessions[next_idx].id)
          return
        end
      end
    end, { buffer = bufnr, desc = "Next Claude session" })
  end

  if keymaps.prev_tab then
    vim.keymap.set({ "n", "t" }, keymaps.prev_tab, function()
      local sessions = get_session_manager().list_sessions()
      local active_id = get_session_manager().get_active_session_id()
      if #sessions <= 1 then
        return
      end
      for i, session in ipairs(sessions) do
        if session.id == active_id then
          local prev_idx = ((i - 2) % #sessions) + 1
          require("claudecode.terminal").switch_to_session(sessions[prev_idx].id)
          return
        end
      end
    end, { buffer = bufnr, desc = "Previous Claude session" })
  end

  if keymaps.new_tab then
    vim.keymap.set({ "n", "t" }, keymaps.new_tab, function()
      require("claudecode.terminal").open_new_session()
    end, { buffer = bufnr, desc = "New Claude session" })
  end

  if keymaps.close_tab then
    vim.keymap.set({ "n", "t" }, keymaps.close_tab, function()
      local active_id = get_session_manager().get_active_session_id()
      if active_id then
        require("claudecode.terminal").close_session(active_id)
      end
    end, { buffer = bufnr, desc = "Close Claude session" })
  end
end

-- ============================================================================
-- Event Handling
-- ============================================================================

local function setup_autocmds()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end

  state.augroup = vim.api.nvim_create_augroup("ClaudeCodeTabBar", { clear = true })

  -- Update on window resize/move
  vim.api.nvim_create_autocmd({ "WinResized", "WinScrolled" }, {
    group = state.augroup,
    callback = function()
      if state.tabbar_win and vim.api.nvim_win_is_valid(state.tabbar_win) then
        M.show()
      end
    end,
  })

  -- Update on session events
  vim.api.nvim_create_autocmd("User", {
    group = state.augroup,
    pattern = { "ClaudeCodeSessionCreated", "ClaudeCodeSessionDestroyed", "ClaudeCodeSessionNameChanged" },
    callback = function()
      M.render()
    end,
  })

  -- Clean up when terminal closes
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    callback = function(args)
      local win = tonumber(args.match)
      if win == state.terminal_win then
        M.hide()
        state.terminal_win = nil
      end
    end,
  })
end

-- ============================================================================
-- Public API
-- ============================================================================

---Initialize the tab bar module
---@param config table Tabs configuration
function M.setup(config)
  state.config = config
  setup_highlights()

  if config and config.enabled then
    setup_autocmds()
    setup_mouse_handler()
  end
end

---Attach tab bar to a terminal window
---@param terminal_win number Terminal window ID
---@param terminal_bufnr number|nil Terminal buffer (for keymaps)
---@param _ any Unused (kept for API compatibility)
function M.attach(terminal_win, terminal_bufnr, _)
  if not state.config or not state.config.enabled then
    return
  end

  state.terminal_win = terminal_win

  if terminal_bufnr then
    M.setup_keymaps(terminal_bufnr)
  end

  M.show()
end

---Detach tab bar
function M.detach()
  M.hide()
  state.terminal_win = nil
end

---Check if tab bar is visible
---@return boolean
function M.is_visible()
  return (state.tabbar_win and vim.api.nvim_win_is_valid(state.tabbar_win))
    or (
      state.terminal_win
      and vim.api.nvim_win_is_valid(state.terminal_win)
      and vim.wo[state.terminal_win].winbar ~= ""
    )
end

---Get tab bar window ID
---@return number|nil
function M.get_winid()
  return state.tabbar_win
end

---Cleanup
function M.cleanup()
  M.hide()

  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end

  if state.tabbar_buf and vim.api.nvim_buf_is_valid(state.tabbar_buf) then
    pcall(vim.api.nvim_buf_delete, state.tabbar_buf, { force = true })
  end

  state.tabbar_buf = nil
  state.tabbar_win = nil
  state.terminal_win = nil
  state.config = nil
end

return M

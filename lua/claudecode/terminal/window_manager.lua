---Window manager for Claude Code terminal.
---Singleton module that owns THE terminal window. Providers create buffers,
---window_manager displays them in the single managed window.
---@module 'claudecode.terminal.window_manager'

local M = {}

local logger = require("claudecode.logger")

---@class WindowManagerState
---@field winid number|nil The single terminal window (nil if closed)
---@field current_bufnr number|nil Buffer currently displayed
---@field config table|nil Window configuration (position, width, etc.)

---@type WindowManagerState
local state = {
  winid = nil,
  current_bufnr = nil,
  config = nil,
  last_width = nil,
  last_height = nil,
  resize_pending = false,
}

---Find any existing terminal window in current tabpage
---@return number|nil winid
local function find_terminal_window()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(current_tab)

  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local buftype = vim.bo[buf].buftype
      if buftype == "terminal" then
        return win
      end
    end
  end

  return nil
end

---Restore the terminal window to its configured width percentage
---@return boolean success
local function restore_configured_width()
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return false
  end
  if not state.config then
    return false
  end
  local split_width_percentage = state.config.split_width_percentage or 0.4
  local total_width = vim.o.columns
  local width = math.floor(total_width * split_width_percentage)
  vim.api.nvim_win_set_width(state.winid, width)
  return true
end

---Create a split window for the terminal
---@param config table Window configuration
---@return number|nil winid
local function create_split_window(config)
  local split_side = config.split_side or "right"
  local split_width_percentage = config.split_width_percentage or 0.4

  -- Calculate dimensions
  local total_width = vim.o.columns
  local width = math.floor(total_width * split_width_percentage)

  -- Create the split
  if split_side == "left" then
    vim.cmd("topleft vertical new")
  else
    vim.cmd("botright vertical new")
  end

  local winid = vim.api.nvim_get_current_win()

  -- Set window width
  vim.api.nvim_win_set_width(winid, width)

  -- Set window options for terminal display
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].winfixwidth = false -- Allow user resizing

  logger.debug("window_manager", "Created split window: " .. winid .. " (width=" .. width .. ")")

  return winid
end

---Notify the terminal of its current dimensions (sends SIGWINCH)
---Call this when window size may have changed.
---Skips the resize if dimensions haven't changed to avoid unnecessary
---SIGWINCH signals that cause TUI applications to redraw and reset scroll.
---@param force? boolean Force resize even if dimensions haven't changed
function M.notify_resize(force)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(state.winid)
  local chan = vim.bo[bufnr].channel
  if chan and chan > 0 then
    local width = vim.api.nvim_win_get_width(state.winid)
    local height = vim.api.nvim_win_get_height(state.winid)
    if not force and width == state.last_width and height == state.last_height then
      logger.debug("window_manager", string.format("Resize skipped (unchanged): %dx%d", width, height))
      return
    end
    state.last_width = width
    state.last_height = height
    pcall(vim.fn.jobresize, chan, width, height)
    logger.debug("window_manager", string.format("Resize notification: %dx%d", width, height))
  end
end

---Setup autocommands for terminal resize notifications
local function setup_resize_autocommands()
  local group = vim.api.nvim_create_augroup("ClaudeCodeTerminalResize", { clear = true })

  -- Handle Neovim window resize
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      restore_configured_width()
      M.notify_resize(true)
    end,
  })

  -- Handle window enter - track terminal window but defer jobresize until the
  -- user actually enters the terminal.  This prevents sidebar toggles (file
  -- explorer, etc.) from sending SIGWINCH which causes the TUI to redraw and
  -- reset its scroll position.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local terminal_win = find_terminal_window()
      if not terminal_win then
        return
      end

      state.winid = terminal_win
      state.current_bufnr = vim.api.nvim_win_get_buf(terminal_win)

      -- Check if the terminal dimensions changed
      local width = vim.api.nvim_win_get_width(terminal_win)
      local height = vim.api.nvim_win_get_height(terminal_win)
      if width ~= state.last_width or height ~= state.last_height then
        -- Dimensions changed – only send jobresize immediately if the user
        -- is entering the terminal window itself (i.e. the entered window IS
        -- the terminal window).  Otherwise mark pending so TermEnter can
        -- flush the resize when the user actually switches to the terminal.
        local entered_win = vim.api.nvim_get_current_win()
        if entered_win == terminal_win then
          M.notify_resize()
        else
          state.resize_pending = true
          -- Still update stored dimensions so we don't re-flag on every WinEnter
          state.last_width = width
          state.last_height = height
          logger.debug("window_manager", string.format("Resize deferred (not in terminal): %dx%d", width, height))
        end
      end
    end,
  })

  -- Handle tab enter (switching between tabs)
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      -- Find terminal window in the new tab and update state
      local terminal_win = find_terminal_window()
      if terminal_win then
        state.winid = terminal_win
        state.current_bufnr = vim.api.nvim_win_get_buf(terminal_win)
        -- Longer delay for tab switches to ensure everything is settled
        vim.defer_fn(function()
          restore_configured_width()
          M.notify_resize()
        end, 100)
      end
    end,
  })

  -- Handle entering terminal mode (pressing i in terminal).
  -- Also flushes any deferred resize so the TUI gets correct dimensions
  -- only when the user is actively interacting with it.
  vim.api.nvim_create_autocmd("TermEnter", {
    group = group,
    callback = function()
      local terminal_win = find_terminal_window()
      if terminal_win then
        state.winid = terminal_win
        state.current_bufnr = vim.api.nvim_win_get_buf(terminal_win)
        if state.resize_pending then
          state.resize_pending = false
          M.notify_resize(true) -- force: stored dims already updated
        else
          M.notify_resize()
        end
      end
    end,
  })
end

---Initialize the window manager with configuration
---@param config table Configuration options
function M.setup(config)
  state.config = config or {}
  setup_resize_autocommands()
  logger.debug("window_manager", "Window manager initialized")
end

---Check winid lives in current tabpage
---@param winid number
---@return boolean
local function win_in_current_tab(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  local ok, tabpage = pcall(vim.api.nvim_win_get_tabpage, winid)
  if not ok then
    return false
  end
  return tabpage == vim.api.nvim_get_current_tabpage()
end

---Get or create the terminal window
---@return number|nil winid
function M.ensure_window()
  -- Return existing window only if valid AND in current tabpage.
  -- A cached winid from another tab would cause display_buffer to jump tabs.
  if state.winid and win_in_current_tab(state.winid) then
    return state.winid
  end

  -- Search current tabpage for an existing terminal window (recovery after
  -- external close, or first open in a new tab).
  local found = find_terminal_window()
  if found then
    state.winid = found
    logger.debug("window_manager", "Recovered existing terminal window: " .. found)
    return found
  end

  -- Create new window (only happens once per visibility cycle)
  if not state.config then
    state.config = {}
  end
  state.winid = create_split_window(state.config)
  return state.winid
end

---Get the current terminal window (nil if none)
---@return number|nil winid
function M.get_window()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    return state.winid
  end
  return nil
end

---Display a buffer in the terminal window
---Creates window if needed, switches buffer if window exists
---Calls jobresize() to notify terminal of dimensions
---@param bufnr number Buffer number to display
---@param focus boolean Whether to focus the window
---@return boolean success
function M.display_buffer(bufnr, focus)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    logger.warn("window_manager", "Cannot display invalid buffer: " .. tostring(bufnr))
    return false
  end

  -- Ensure window exists
  local winid = M.ensure_window()
  if not winid then
    logger.error("window_manager", "Failed to create terminal window")
    return false
  end

  -- Get current buffer in window (for scratch buffer cleanup)
  local current_buf = vim.api.nvim_win_get_buf(winid)
  local current_bufname = vim.api.nvim_buf_get_name(current_buf)
  local is_scratch = current_bufname == "" and vim.bo[current_buf].buftype == ""

  -- Switch buffer in window (THE KEY OPERATION)
  vim.api.nvim_win_set_buf(winid, bufnr)
  state.current_bufnr = bufnr

  -- Clean up scratch buffer created by :new
  if is_scratch and current_buf ~= bufnr and vim.api.nvim_buf_is_valid(current_buf) then
    pcall(vim.api.nvim_buf_delete, current_buf, { force = true })
  end

  -- Notify terminal of dimensions (critical for cursor position)
  local chan = vim.bo[bufnr].channel
  if chan and chan > 0 then
    local width = vim.api.nvim_win_get_width(winid)
    local height = vim.api.nvim_win_get_height(winid)
    pcall(vim.fn.jobresize, chan, width, height)
    logger.debug("window_manager", string.format("Resized terminal channel %d to %dx%d", chan, width, height))
  end

  -- Focus if requested
  if focus then
    vim.api.nvim_set_current_win(winid)
    vim.cmd("startinsert")
  end

  logger.debug("window_manager", "Displayed buffer " .. bufnr .. " in window " .. winid)
  return true
end

---Close the terminal window
function M.close_window()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    -- Don't force close - let normal window close happen
    pcall(vim.api.nvim_win_close, state.winid, false)
    logger.debug("window_manager", "Closed terminal window: " .. state.winid)
  end
  state.winid = nil
  state.current_bufnr = nil
end

---Check if terminal window is visible in the current tabpage
---@return boolean
function M.is_visible()
  return state.winid ~= nil and win_in_current_tab(state.winid)
end

---Get window dimensions
---@return table|nil dimensions {width, height} or nil if no window
function M.get_dimensions()
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return nil
  end

  return {
    width = vim.api.nvim_win_get_width(state.winid),
    height = vim.api.nvim_win_get_height(state.winid),
  }
end

---Get currently displayed buffer
---@return number|nil bufnr
function M.get_current_buffer()
  return state.current_bufnr
end

---Reset state (for testing or cleanup)
function M.reset()
  M.close_window()
  state = {
    winid = nil,
    current_bufnr = nil,
    config = nil,
    last_width = nil,
    last_height = nil,
  }
  logger.debug("window_manager", "Reset window manager state")
end

return M

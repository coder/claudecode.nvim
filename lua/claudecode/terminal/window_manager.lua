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

---Create a split window for the terminal
---@param config table Window configuration
---@return number|nil winid
local function create_split_window(config)
  local split_side = config.split_side or "right"
  local split_width_percentage = config.split_width_percentage or 0.4

  -- Calculate dimensions
  local total_width = vim.o.columns
  local width = math.floor(total_width * split_width_percentage)

  -- Save current window to restore later if needed
  local current_win = vim.api.nvim_get_current_win()

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

---Initialize the window manager with configuration
---@param config table Configuration options
function M.setup(config)
  state.config = config or {}
  logger.debug("window_manager", "Window manager initialized")
end

---Get or create the terminal window
---@return number|nil winid
function M.ensure_window()
  -- Return existing window if valid
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    return state.winid
  end

  -- Search for any existing terminal window (recovery after external close)
  state.winid = find_terminal_window()
  if state.winid then
    logger.debug("window_manager", "Recovered existing terminal window: " .. state.winid)
    return state.winid
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

---Check if terminal window is visible
---@return boolean
function M.is_visible()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
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
  }
  logger.debug("window_manager", "Reset window manager state")
end

return M

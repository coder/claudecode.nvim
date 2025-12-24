---Terminal title watcher for session naming.
---Watches vim.b.term_title to capture terminal title set by Claude CLI.
---@module 'claudecode.terminal.osc_handler'

local M = {}

local logger = require("claudecode.logger")

-- Storage for buffer handlers
---@type table<number, { augroup: number, timer: userdata|nil, callback: function, last_title: string|nil }>
local handlers = {}

-- Timer interval in milliseconds
local POLL_INTERVAL_MS = 2000
local INITIAL_DELAY_MS = 500

---Strip common prefixes from title (like "Claude - ")
---@param title string The raw title
---@return string title The cleaned title
function M.clean_title(title)
  if not title then
    return title
  end

  -- Strip "Claude - " prefix (case insensitive)
  title = title:gsub("^[Cc]laude %- ", "")

  -- Strip leading/trailing whitespace
  title = title:gsub("^%s+", ""):gsub("%s+$", "")

  -- Limit length to prevent issues
  if #title > 100 then
    title = title:sub(1, 97) .. "..."
  end

  return title
end

---Setup title watcher for a terminal buffer
---Watches vim.b.term_title for changes and calls callback when title changes
---@param bufnr number The terminal buffer number
---@param callback function Called with (title: string) when title changes
function M.setup_buffer_handler(bufnr, callback)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    logger.warn("osc_handler", "Cannot setup handler for invalid buffer")
    return
  end

  -- Clean up existing handler if any
  M.cleanup_buffer_handler(bufnr)

  -- Create autocommand group for this buffer
  local augroup = vim.api.nvim_create_augroup("ClaudeCodeTitle_" .. bufnr, { clear = true })

  -- Store handler info with last_title for change detection
  handlers[bufnr] = {
    augroup = augroup,
    timer = nil,
    callback = callback,
    last_title = nil,
  }

  ---Check title and call callback if changed
  local function check_title()
    local handler = handlers[bufnr]
    if not handler then
      return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
      M.cleanup_buffer_handler(bufnr)
      return
    end

    -- Read term_title from buffer
    local current_title = vim.b[bufnr].term_title
    if not current_title or current_title == "" then
      return
    end

    -- Check if title changed
    if current_title == handler.last_title then
      return
    end

    handler.last_title = current_title

    -- Clean the title
    local cleaned = M.clean_title(current_title)
    if not cleaned or cleaned == "" then
      return
    end

    logger.debug("osc_handler", "Terminal title changed: " .. cleaned)

    -- Call the callback
    if handler.callback then
      handler.callback(cleaned)
    end
  end

  -- Check on TermEnter (when user enters terminal)
  vim.api.nvim_create_autocmd("TermEnter", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      vim.schedule(check_title)
    end,
    desc = "Claude Code terminal title check on enter",
  })

  -- Check on BufEnter as well (sometimes TermEnter doesn't fire)
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      vim.schedule(check_title)
    end,
    desc = "Claude Code terminal title check on buffer enter",
  })

  -- Also poll periodically for background title updates
  local timer = vim.loop.new_timer()
  if timer then
    timer:start(
      INITIAL_DELAY_MS,
      POLL_INTERVAL_MS,
      vim.schedule_wrap(function()
        -- Check if handler still exists and buffer is valid
        if handlers[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
          check_title()
        else
          -- Stop timer if buffer is gone
          if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
          end
        end
      end)
    )
    handlers[bufnr].timer = timer
  end

  logger.debug("osc_handler", "Setup title watcher for buffer " .. bufnr)
end

---Cleanup title watcher for a buffer
---@param bufnr number The terminal buffer number
function M.cleanup_buffer_handler(bufnr)
  local handler = handlers[bufnr]
  if not handler then
    return
  end

  -- Stop and close the timer
  if handler.timer then
    if not handler.timer:is_closing() then
      handler.timer:stop()
      handler.timer:close()
    end
    handler.timer = nil
  end

  -- Delete the autocommand group
  pcall(vim.api.nvim_del_augroup_by_id, handler.augroup)

  -- Remove from storage
  handlers[bufnr] = nil

  logger.debug("osc_handler", "Cleaned up title watcher for buffer " .. bufnr)
end

---Check if a buffer has a title watcher registered
---@param bufnr number The buffer number
---@return boolean
function M.has_handler(bufnr)
  return handlers[bufnr] ~= nil
end

---Get handler count (for testing)
---@return number
function M._get_handler_count()
  local count = 0
  for _ in pairs(handlers) do
    count = count + 1
  end
  return count
end

---Reset all handlers (for testing)
function M._reset()
  for bufnr, _ in pairs(handlers) do
    M.cleanup_buffer_handler(bufnr)
  end
  handlers = {}
end

-- Keep parse_osc_title for backwards compatibility and testing
-- even though we no longer use TermRequest

---Parse OSC title from escape sequence data (legacy, kept for testing)
---Handles OSC 0 (icon + title) and OSC 2 (title only)
---Format: ESC ] Ps ; Pt BEL or ESC ] Ps ; Pt ST
---@param data string The raw escape sequence data
---@return string|nil title The extracted title, or nil if not a title sequence
function M.parse_osc_title(data)
  if not data or data == "" then
    return nil
  end

  local _, content

  -- Pattern 1: ESC ] 0/2 ; title BEL
  _, content = data:match("^\027%]([02]);(.-)\007$")
  if content then
    content = content:gsub("^%s+", ""):gsub("%s+$", "")
    return content ~= "" and content or nil
  end

  -- Pattern 2: ESC ] 0/2 ; title ST (ESC \)
  _, content = data:match("^\027%]([02]);(.-)\027\\$")
  if content then
    content = content:gsub("^%s+", ""):gsub("%s+$", "")
    return content ~= "" and content or nil
  end

  -- Pattern 3: ] 0/2 ; title (ESC prefix already stripped)
  _, content = data:match("^%]([02]);(.-)$")
  if content then
    -- Remove any trailing control characters
    content = content:gsub("[\007\027%z\\].*$", "")
    content = content:gsub("^%s+", ""):gsub("%s+$", "")
    return content ~= "" and content or nil
  end

  return nil
end

return M

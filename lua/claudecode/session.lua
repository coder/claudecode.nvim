---Session manager for multiple Claude Code terminal sessions.
---Provides full session isolation with independent state tracking per session.
---@module 'claudecode.session'

local M = {}

local logger = require("claudecode.logger")

---@class ClaudeCodeSession
---@field id string Unique session identifier
---@field terminal_bufnr number|nil Buffer number for the terminal
---@field terminal_winid number|nil Window ID for the terminal
---@field terminal_jobid number|nil Job ID for the terminal process
---@field client_id string|nil Bound WebSocket client ID
---@field selection table|nil Session-specific selection state
---@field mention_queue table Queue for @ mentions
---@field created_at number Timestamp when session was created
---@field name string|nil Optional display name for the session

---@type table<string, ClaudeCodeSession>
M.sessions = {}

---@type string|nil Currently active session ID
M.active_session_id = nil

---@type number Session counter for generating sequential IDs
local session_counter = 0

---Generate a unique session ID
---@return string session_id
local function generate_session_id()
  session_counter = session_counter + 1
  return string.format("session_%d_%d", session_counter, vim.loop.now())
end

---Create a new session
---@param opts table|nil Optional configuration { name?: string }
---@return string session_id The ID of the created session
function M.create_session(opts)
  opts = opts or {}
  local session_id = generate_session_id()

  ---@type ClaudeCodeSession
  local session = {
    id = session_id,
    terminal_bufnr = nil,
    terminal_winid = nil,
    terminal_jobid = nil,
    client_id = nil,
    selection = nil,
    mention_queue = {},
    created_at = vim.loop.now(),
    name = opts.name or string.format("Session %d", session_counter),
  }

  M.sessions[session_id] = session

  -- If this is the first session, make it active
  if not M.active_session_id then
    M.active_session_id = session_id
  end

  logger.debug("session", "Created session: " .. session_id .. " (" .. session.name .. ")")

  return session_id
end

---Destroy a session and clean up resources
---@param session_id string The session ID to destroy
---@return boolean success Whether the session was destroyed
function M.destroy_session(session_id)
  local session = M.sessions[session_id]
  if not session then
    logger.warn("session", "Cannot destroy non-existent session: " .. session_id)
    return false
  end

  -- Clear mention queue
  session.mention_queue = {}

  -- Clean up selection state
  session.selection = nil

  -- Remove from sessions table
  M.sessions[session_id] = nil

  -- If this was the active session, switch to another or clear
  if M.active_session_id == session_id then
    -- Get first available session using next()
    local next_session_id = next(M.sessions)
    M.active_session_id = next_session_id
  end

  logger.debug("session", "Destroyed session: " .. session_id)

  return true
end

---Get a session by ID
---@param session_id string The session ID
---@return ClaudeCodeSession|nil session The session or nil if not found
function M.get_session(session_id)
  return M.sessions[session_id]
end

---Get the active session
---@return ClaudeCodeSession|nil session The active session or nil
function M.get_active_session()
  if not M.active_session_id then
    return nil
  end
  return M.sessions[M.active_session_id]
end

---Get the active session ID
---@return string|nil session_id The active session ID or nil
function M.get_active_session_id()
  return M.active_session_id
end

---Set the active session
---@param session_id string The session ID to make active
---@return boolean success Whether the session was activated
function M.set_active_session(session_id)
  if not M.sessions[session_id] then
    logger.warn("session", "Cannot activate non-existent session: " .. session_id)
    return false
  end

  M.active_session_id = session_id
  logger.debug("session", "Activated session: " .. session_id)

  return true
end

---List all sessions
---@return ClaudeCodeSession[] sessions Array of all sessions
function M.list_sessions()
  local sessions = {}
  for _, session in pairs(M.sessions) do
    table.insert(sessions, session)
  end

  -- Sort by creation time
  table.sort(sessions, function(a, b)
    return a.created_at < b.created_at
  end)

  return sessions
end

---Get session count
---@return number count Number of active sessions
function M.get_session_count()
  local count = 0
  for _ in pairs(M.sessions) do
    count = count + 1
  end
  return count
end

---Find session by terminal buffer number
---@param bufnr number The buffer number to search for
---@return ClaudeCodeSession|nil session The session or nil
function M.find_session_by_bufnr(bufnr)
  for _, session in pairs(M.sessions) do
    if session.terminal_bufnr == bufnr then
      return session
    end
  end
  return nil
end

---Find session by WebSocket client ID
---@param client_id string The client ID to search for
---@return ClaudeCodeSession|nil session The session or nil
function M.find_session_by_client(client_id)
  for _, session in pairs(M.sessions) do
    if session.client_id == client_id then
      return session
    end
  end
  return nil
end

---Bind a WebSocket client to a session
---@param session_id string The session ID
---@param client_id string The client ID to bind
---@return boolean success Whether the binding was successful
function M.bind_client(session_id, client_id)
  local session = M.sessions[session_id]
  if not session then
    logger.warn("session", "Cannot bind client to non-existent session: " .. session_id)
    return false
  end

  -- Check if client is already bound to another session
  local existing_session = M.find_session_by_client(client_id)
  if existing_session and existing_session.id ~= session_id then
    logger.warn("session", "Client " .. client_id .. " already bound to session " .. existing_session.id)
    return false
  end

  session.client_id = client_id
  logger.debug("session", "Bound client " .. client_id .. " to session " .. session_id)

  return true
end

---Unbind a WebSocket client from its session
---@param client_id string The client ID to unbind
---@return boolean success Whether the unbinding was successful
function M.unbind_client(client_id)
  local session = M.find_session_by_client(client_id)
  if not session then
    return false
  end

  session.client_id = nil
  logger.debug("session", "Unbound client " .. client_id .. " from session " .. session.id)

  return true
end

---Update session terminal info
---@param session_id string The session ID
---@param terminal_info table { bufnr?: number, winid?: number, jobid?: number }
function M.update_terminal_info(session_id, terminal_info)
  local session = M.sessions[session_id]
  if not session then
    return
  end

  if terminal_info.bufnr ~= nil then
    session.terminal_bufnr = terminal_info.bufnr
  end
  if terminal_info.winid ~= nil then
    session.terminal_winid = terminal_info.winid
  end
  if terminal_info.jobid ~= nil then
    session.terminal_jobid = terminal_info.jobid
  end
end

---Update session selection
---@param session_id string The session ID
---@param selection table|nil The selection data
function M.update_selection(session_id, selection)
  local session = M.sessions[session_id]
  if not session then
    return
  end

  session.selection = selection
end

---Update session name (typically from terminal title)
---@param session_id string The session ID
---@param name string The new name
function M.update_session_name(session_id, name)
  local session = M.sessions[session_id]
  if not session then
    logger.warn("session", "Cannot update name for non-existent session: " .. session_id)
    return
  end

  -- Strip "Claude - " prefix (redundant for Claude sessions)
  name = name:gsub("^[Cc]laude %- ", "")

  -- Sanitize: trim whitespace and limit length
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if #name > 100 then
    name = name:sub(1, 97) .. "..."
  end

  -- Don't update if name is empty or unchanged
  if name == "" or session.name == name then
    return
  end

  local old_name = session.name
  session.name = name

  logger.debug("session", string.format("Updated session name: '%s' -> '%s' (%s)", old_name, name, session_id))

  -- Emit autocmd event for UI integrations (statusline, session pickers, etc.)
  -- Use pcall to handle case where nvim_exec_autocmds may not exist (e.g., in tests)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "ClaudeCodeSessionNameChanged",
    data = { session_id = session_id, name = name, old_name = old_name },
  })
end

---Get session selection
---@param session_id string The session ID
---@return table|nil selection The selection data or nil
function M.get_selection(session_id)
  local session = M.sessions[session_id]
  if not session then
    return nil
  end

  return session.selection
end

---Add mention to session queue
---@param session_id string The session ID
---@param mention table The mention data
function M.queue_mention(session_id, mention)
  local session = M.sessions[session_id]
  if not session then
    return
  end

  table.insert(session.mention_queue, mention)
end

---Get and clear session mention queue
---@param session_id string The session ID
---@return table mentions Array of mentions
function M.flush_mention_queue(session_id)
  local session = M.sessions[session_id]
  if not session then
    return {}
  end

  local mentions = session.mention_queue
  session.mention_queue = {}
  return mentions
end

---Get or create a session (ensures at least one session exists)
---@return string session_id The session ID
function M.ensure_session()
  if M.active_session_id and M.sessions[M.active_session_id] then
    return M.active_session_id
  end

  -- No active session, create one
  return M.create_session()
end

---Reset all session state (for testing or cleanup)
function M.reset()
  M.sessions = {}
  M.active_session_id = nil
  session_counter = 0
  logger.debug("session", "Reset all sessions")
end

return M

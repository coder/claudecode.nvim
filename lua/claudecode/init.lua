---@brief [[
--- Claude Code Neovim Integration
--- This plugin integrates Claude Code CLI with Neovim, enabling
--- seamless AI-assisted coding experiences directly in Neovim.
---@brief ]]

---@module 'claudecode'
local M = {}

local logger = require("claudecode.logger")

--- Current plugin version
---@type ClaudeCodeVersion
M.version = {
  major = 0,
  minor = 2,
  patch = 0,
  prerelease = nil,
  string = function(self)
    local version = string.format("%d.%d.%d", self.major, self.minor, self.patch)
    if self.prerelease then
      version = version .. "-" .. self.prerelease
    end
    return version
  end,
}

-- Module state
---@type ClaudeCodeState
M.state = {
  config = require("claudecode.config").defaults,
  server = nil,
  port = nil,
  auth_token = nil,
  initialized = false,
  mention_queue = {},
  mention_timer = nil,
  connection_timer = nil,
}

---Check if Claude Code is connected to WebSocket server
---@return boolean connected Whether Claude Code has active connections
function M.is_claude_connected()
  if not M.state.server then
    return false
  end

  local server_module = require("claudecode.server.init")
  local status = server_module.get_status()
  if not status.running then
    return false
  end

  -- Prefer handshake-aware check when client info is available; otherwise fall back to client_count
  if status.clients and #status.clients > 0 then
    for _, info in ipairs(status.clients) do
      if (info.state == "connected" or info.handshake_complete == true) and info.handshake_complete == true then
        return true
      end
    end
    return false
  else
    return status.client_count and status.client_count > 0
  end
end

---Clear the mention queue and stop any pending timer
local function clear_mention_queue()
  -- Initialize mention_queue if it doesn't exist (for test compatibility)
  if not M.state.mention_queue then
    M.state.mention_queue = {}
  else
    if #M.state.mention_queue > 0 then
      logger.debug("queue", "Clearing " .. #M.state.mention_queue .. " queued @ mentions")
    end
    M.state.mention_queue = {}
  end

  if M.state.mention_timer then
    M.state.mention_timer:stop()
    M.state.mention_timer:close()
    M.state.mention_timer = nil
  end
end

---Process mentions when Claude is connected (debounced mode)
local function process_connected_mentions()
  -- Reset the debounce timer
  if M.state.mention_timer then
    M.state.mention_timer:stop()
    M.state.mention_timer:close()
  end

  -- Set a new timer to process the queue after 50ms of inactivity
  M.state.mention_timer = vim.loop.new_timer()
  local debounce_delay = math.max(10, 50) -- Minimum 10ms debounce, 50ms for batching

  -- Use vim.schedule_wrap if available, otherwise fallback to vim.schedule + function call
  local wrapped_function = vim.schedule_wrap and vim.schedule_wrap(M.process_mention_queue)
    or function()
      vim.schedule(M.process_mention_queue)
    end

  M.state.mention_timer:start(debounce_delay, 0, wrapped_function)
end

---Start connection timeout timer if not already started
local function start_connection_timeout_if_needed()
  if not M.state.connection_timer then
    M.state.connection_timer = vim.loop.new_timer()
    M.state.connection_timer:start(M.state.config.connection_timeout, 0, function()
      vim.schedule(function()
        if #M.state.mention_queue > 0 then
          logger.error("queue", "Connection timeout - clearing " .. #M.state.mention_queue .. " queued @ mentions")
          clear_mention_queue()
        end
      end)
    end)
  end
end

---Add @ mention to queue
---@param file_path string The file path to mention
---@param start_line number|nil Optional start line
---@param end_line number|nil Optional end line
local function queue_mention(file_path, start_line, end_line)
  -- Initialize mention_queue if it doesn't exist (for test compatibility)
  if not M.state.mention_queue then
    M.state.mention_queue = {}
  end

  local mention_data = {
    file_path = file_path,
    start_line = start_line,
    end_line = end_line,
    timestamp = vim.loop.now(),
  }

  table.insert(M.state.mention_queue, mention_data)
  logger.debug("queue", "Queued @ mention: " .. file_path .. " (queue size: " .. #M.state.mention_queue .. ")")

  -- Process based on connection state
  if M.is_claude_connected() then
    -- Connected: Use debounced processing (old broadcast_queue behavior)
    process_connected_mentions()
  else
    -- Disconnected: Start connection timeout timer (old queued_mentions behavior)
    start_connection_timeout_if_needed()
  end
end

---Process the mention queue (handles both connected and disconnected modes)
---@param from_new_connection boolean|nil Whether this is triggered by a new connection (adds delay)
function M.process_mention_queue(from_new_connection)
  -- Initialize mention_queue if it doesn't exist (for test compatibility)
  if not M.state.mention_queue then
    M.state.mention_queue = {}
    return
  end

  if #M.state.mention_queue == 0 then
    return
  end

  if not M.is_claude_connected() then
    -- Still disconnected or handshake not complete yet, wait for readiness
    logger.debug("queue", "Claude not ready (no handshake). Keeping ", #M.state.mention_queue, " mentions queued")

    -- If triggered by a new connection, poll until handshake completes (bounded by connection_timeout timer)
    if from_new_connection then
      local retry_delay = math.max(50, math.floor((M.state.config.connection_wait_delay or 200) / 4))
      vim.defer_fn(function()
        M.process_mention_queue(true)
      end, retry_delay)
    end
    return
  end

  local mentions_to_send = vim.deepcopy(M.state.mention_queue)
  M.state.mention_queue = {} -- Clear queue

  -- Stop any existing timer
  if M.state.mention_timer then
    M.state.mention_timer:stop()
    M.state.mention_timer:close()
    M.state.mention_timer = nil
  end

  -- Stop connection timer since we're now connected
  if M.state.connection_timer then
    M.state.connection_timer:stop()
    M.state.connection_timer:close()
    M.state.connection_timer = nil
  end

  logger.debug("queue", "Processing " .. #mentions_to_send .. " queued @ mentions")

  -- Send mentions with a small delay between each to prevent WebSocket/extension overwhelm
  local function send_mention_sequential(index)
    if index > #mentions_to_send then
      logger.debug("queue", "All queued mentions sent successfully")
      return
    end

    local mention = mentions_to_send[index]

    -- Check if mention has expired (same timeout logic as old system)
    local current_time = vim.loop.now()
    if (current_time - mention.timestamp) > M.state.config.queue_timeout then
      logger.debug("queue", "Skipped expired @ mention: " .. mention.file_path)
    else
      -- Directly broadcast without going through the queue system to avoid infinite recursion
      local params = {
        filePath = mention.file_path,
        lineStart = mention.start_line,
        lineEnd = mention.end_line,
      }

      local broadcast_success = M.state.server.broadcast("at_mentioned", params)
      if broadcast_success then
        logger.debug("queue", "Sent queued @ mention: " .. mention.file_path)
      else
        logger.error("queue", "Failed to send queued @ mention: " .. mention.file_path)
      end
    end

    -- Process next mention with delay
    if index < #mentions_to_send then
      local inter_message_delay = 25 -- ms
      vim.defer_fn(function()
        send_mention_sequential(index + 1)
      end, inter_message_delay)
    end
  end

  -- Apply delay for new connections, send immediately for debounced processing
  if #mentions_to_send > 0 then
    if from_new_connection then
      -- Wait for connection_wait_delay when processing queue after new connection
      local initial_delay = (M.state.config and M.state.config.connection_wait_delay) or 200
      logger.debug("queue", "Waiting ", initial_delay, "ms after connect before flushing queue")
      vim.defer_fn(function()
        send_mention_sequential(1)
      end, initial_delay)
    else
      -- Send immediately for debounced processing (Claude already connected)
      send_mention_sequential(1)
    end
  end
end

---Show terminal if Claude is connected and it's not already visible
---@return boolean success Whether terminal was shown or was already visible
function M._ensure_terminal_visible_if_connected()
  if not M.is_claude_connected() then
    return false
  end

  local terminal = require("claudecode.terminal")
  local active_bufnr = terminal.get_active_terminal_bufnr and terminal.get_active_terminal_bufnr()

  if not active_bufnr then
    return false
  end

  local bufinfo = vim.fn.getbufinfo(active_bufnr)[1]
  local is_visible = bufinfo and #bufinfo.windows > 0

  if not is_visible then
    terminal.simple_toggle()
  end

  return true
end

---Send @ mention to Claude Code, handling connection state automatically
---@param file_path string The file path to send
---@param start_line number|nil Start line (0-indexed for Claude)
---@param end_line number|nil End line (0-indexed for Claude)
---@param context string|nil Context for logging
---@return boolean success Whether the operation was successful
---@return string|nil error Error message if failed
function M.send_at_mention(file_path, start_line, end_line, context)
  context = context or "command"

  if not M.state.server then
    logger.error(context, "Claude Code integration is not running")
    return false, "Claude Code integration is not running"
  end

  -- Check if Claude Code is connected
  if M.is_claude_connected() then
    -- Claude is connected, send immediately and ensure terminal is visible
    local success, error_msg = M._broadcast_at_mention(file_path, start_line, end_line)
    if success then
      local terminal = require("claudecode.terminal")
      if M.state.config and M.state.config.focus_after_send then
        -- Open focuses the terminal without toggling/hiding if already focused
        terminal.open()
      else
        terminal.ensure_visible()
      end
    end
    return success, error_msg
  else
    -- Claude not connected, queue the mention and launch terminal
    queue_mention(file_path, start_line, end_line)

    -- Launch terminal with Claude Code
    local terminal = require("claudecode.terminal")
    terminal.open()

    logger.debug(context, "Queued @ mention and launched Claude Code: " .. file_path)

    return true, nil
  end
end

---Set up the plugin with user configuration
---@param opts PartialClaudeCodeConfig|nil Optional configuration table to override defaults.
---@return table module The plugin module
function M.setup(opts)
  opts = opts or {}

  local config = require("claudecode.config")
  M.state.config = config.apply(opts)
  -- vim.g.claudecode_user_config is no longer needed as config values are passed directly.

  logger.setup(M.state.config)

  -- Setup terminal module: always try to call setup to pass terminal_cmd and env,
  -- even if terminal_opts (for split_side etc.) are not provided.
  -- Map top-level cwd-related aliases into terminal config for convenience
  do
    local t = opts.terminal or {}
    local had_alias = false
    if opts.git_repo_cwd ~= nil then
      t.git_repo_cwd = opts.git_repo_cwd
      had_alias = true
    end
    if opts.cwd ~= nil then
      t.cwd = opts.cwd
      had_alias = true
    end
    if opts.cwd_provider ~= nil then
      t.cwd_provider = opts.cwd_provider
      had_alias = true
    end
    if had_alias then
      opts.terminal = t
    end
  end

  local terminal_setup_ok, terminal_module = pcall(require, "claudecode.terminal")
  if terminal_setup_ok then
    -- Guard in case tests or user replace the module with a minimal stub without `setup`.
    if type(terminal_module.setup) == "function" then
      -- terminal_opts might be nil, which the setup function should handle gracefully.
      terminal_module.setup(opts.terminal, M.state.config.terminal_cmd, M.state.config.env)
    end
  else
    logger.error("init", "Failed to load claudecode.terminal module for setup.")
  end

  local diff = require("claudecode.diff")
  diff.setup(M.state.config)

  if M.state.config.auto_start then
    M.start(false) -- Suppress notification on auto-start
  end

  M._create_commands()

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("ClaudeCodeShutdown", { clear = true }),
    callback = function()
      if M.state.server then
        M.stop()
      else
        -- Clear queue even if server isn't running
        clear_mention_queue()
      end
    end,
    desc = "Automatically stop Claude Code integration when exiting Neovim",
  })

  M.state.initialized = true
  return M
end

---Start the Claude Code integration
---@param show_startup_notification? boolean Whether to show a notification upon successful startup (defaults to true)
---@return boolean success Whether the operation was successful
---@return number|string port_or_error The WebSocket port if successful, or error message if failed
function M.start(show_startup_notification)
  if show_startup_notification == nil then
    show_startup_notification = true
  end
  if M.state.server then
    local msg = "Claude Code integration is already running on port " .. tostring(M.state.port)
    logger.warn("init", msg)
    return false, "Already running"
  end

  local server = require("claudecode.server.init")
  local lockfile = require("claudecode.lockfile")

  -- Generate auth token first so we can pass it to the server
  local auth_token
  local auth_success, auth_result = pcall(function()
    return lockfile.generate_auth_token()
  end)

  if not auth_success then
    local error_msg = "Failed to generate authentication token: " .. (auth_result or "unknown error")
    logger.error("init", error_msg)
    return false, error_msg
  end

  auth_token = auth_result

  -- Validate the generated auth token
  if not auth_token or type(auth_token) ~= "string" or #auth_token < 10 then
    local error_msg = "Invalid authentication token generated"
    logger.error("init", error_msg)
    return false, error_msg
  end

  local success, result = server.start(M.state.config, auth_token)

  if not success then
    local error_msg = "Failed to start Claude Code server: " .. (result or "unknown error")
    if result and result:find("auth") then
      error_msg = error_msg .. " (authentication related)"
    end
    logger.error("init", error_msg)
    return false, error_msg
  end

  M.state.server = server
  M.state.port = tonumber(result)
  M.state.auth_token = auth_token

  local lock_success, lock_result, returned_auth_token = lockfile.create(M.state.port, auth_token)

  if not lock_success then
    server.stop()
    M.state.server = nil
    M.state.port = nil
    M.state.auth_token = nil

    local error_msg = "Failed to create lock file: " .. (lock_result or "unknown error")
    if lock_result and lock_result:find("auth") then
      error_msg = error_msg .. " (authentication token issue)"
    end
    logger.error("init", error_msg)
    return false, error_msg
  end

  -- Verify that the auth token in the lock file matches what we generated
  if returned_auth_token ~= auth_token then
    server.stop()
    M.state.server = nil
    M.state.port = nil
    M.state.auth_token = nil

    local error_msg = "Authentication token mismatch between server and lock file"
    logger.error("init", error_msg)
    return false, error_msg
  end

  if M.state.config.track_selection then
    local selection = require("claudecode.selection")
    selection.enable(M.state.server, M.state.config.visual_demotion_delay_ms)
  end

  if show_startup_notification then
    logger.info("init", "Claude Code integration started on port " .. tostring(M.state.port))
  end

  return true, M.state.port
end

---Stop the Claude Code integration
---@return boolean success Whether the operation was successful
---@return string|nil error Error message if operation failed
function M.stop()
  if not M.state.server then
    logger.warn("init", "Claude Code integration is not running")
    return false, "Not running"
  end

  local lockfile = require("claudecode.lockfile")
  local lock_success, lock_error = lockfile.remove(M.state.port)

  if not lock_success then
    logger.warn("init", "Failed to remove lock file: " .. lock_error)
    -- Continue with shutdown even if lock file removal fails
  end

  if M.state.config.track_selection then
    local selection = require("claudecode.selection")
    selection.disable()
  end

  local success, error = M.state.server.stop()

  if not success then
    logger.error("init", "Failed to stop Claude Code integration: " .. error)
    return false, error
  end

  M.state.server = nil
  M.state.port = nil
  M.state.auth_token = nil

  -- Clear any queued @ mentions when server stops
  clear_mention_queue()

  logger.info("init", "Claude Code integration stopped")

  return true
end

---Set up user commands
---@private
function M._create_commands()
  vim.api.nvim_create_user_command("ClaudeCodeStart", function()
    M.start()
  end, {
    desc = "Start Claude Code integration",
  })

  vim.api.nvim_create_user_command("ClaudeCodeStop", function()
    M.stop()
  end, {
    desc = "Stop Claude Code integration",
  })

  vim.api.nvim_create_user_command("ClaudeCodeStatus", function()
    if M.state.server and M.state.port then
      logger.info("command", "Claude Code integration is running on port " .. tostring(M.state.port))
    else
      logger.info("command", "Claude Code integration is not running")
    end
  end, {
    desc = "Show Claude Code integration status",
  })

  ---@param file_paths table List of file paths to add
  ---@param options table|nil Optional settings: { delay?: number, show_summary?: boolean, context?: string }
  ---@return number success_count Number of successfully added files
  ---@return number total_count Total number of files attempted
  local function add_paths_to_claude(file_paths, options)
    options = options or {}
    local delay = options.delay or 0
    local show_summary = options.show_summary ~= false
    local context = options.context or "command"

    if not file_paths or #file_paths == 0 then
      return 0, 0
    end

    local success_count = 0
    local total_count = #file_paths

    if delay > 0 then
      local function send_files_sequentially(index)
        if index > total_count then
          if show_summary then
            local message = success_count == 1 and "Added 1 file to Claude context"
              or string.format("Added %d files to Claude context", success_count)
            if total_count > success_count then
              message = message .. string.format(" (%d failed)", total_count - success_count)
            end

            if total_count > success_count then
              if success_count > 0 then
                logger.warn(context, message)
              else
                logger.error(context, message)
              end
            elseif success_count > 0 then
              logger.info(context, message)
            else
              logger.debug(context, message)
            end
          end
          return
        end

        local file_path = file_paths[index]
        local success, error_msg = M.send_at_mention(file_path, nil, nil, context)
        if success then
          success_count = success_count + 1
        else
          logger.error(context, "Failed to add file: " .. file_path .. " - " .. (error_msg or "unknown error"))
        end

        if index < total_count then
          vim.defer_fn(function()
            send_files_sequentially(index + 1)
          end, delay)
        else
          if show_summary then
            local message = success_count == 1 and "Added 1 file to Claude context"
              or string.format("Added %d files to Claude context", success_count)
            if total_count > success_count then
              message = message .. string.format(" (%d failed)", total_count - success_count)
            end

            if total_count > success_count then
              if success_count > 0 then
                logger.warn(context, message)
              else
                logger.error(context, message)
              end
            elseif success_count > 0 then
              logger.info(context, message)
            else
              logger.debug(context, message)
            end
          end
        end
      end

      send_files_sequentially(1)
    else
      for _, file_path in ipairs(file_paths) do
        local success, error_msg = M.send_at_mention(file_path, nil, nil, context)
        if success then
          success_count = success_count + 1
        else
          logger.error(context, "Failed to add file: " .. file_path .. " - " .. (error_msg or "unknown error"))
        end
      end

      if show_summary and success_count > 0 then
        local message = success_count == 1 and "Added 1 file to Claude context"
          or string.format("Added %d files to Claude context", success_count)
        if total_count > success_count then
          message = message .. string.format(" (%d failed)", total_count - success_count)
        end
        logger.debug(context, message)
      end
    end

    return success_count, total_count
  end

  local function handle_send_normal(opts)
    local current_ft = (vim.bo and vim.bo.filetype) or ""
    local current_bufname = (vim.api and vim.api.nvim_buf_get_name and vim.api.nvim_buf_get_name(0)) or ""

    local is_tree_buffer = current_ft == "NvimTree"
      or current_ft == "neo-tree"
      or current_ft == "oil"
      or current_ft == "minifiles"
      or current_ft == "netrw"
      or string.match(current_bufname, "neo%-tree")
      or string.match(current_bufname, "NvimTree")
      or string.match(current_bufname, "minifiles://")

    if is_tree_buffer then
      local integrations = require("claudecode.integrations")
      local files, error = integrations.get_selected_files_from_tree()

      if error then
        logger.error("command", "ClaudeCodeSend->TreeAdd: " .. error)
        return
      end

      if not files or #files == 0 then
        logger.warn("command", "ClaudeCodeSend->TreeAdd: No files selected")
        return
      end

      add_paths_to_claude(files, { context = "ClaudeCodeSend->TreeAdd" })

      return
    end

    local selection_module_ok, selection_module = pcall(require, "claudecode.selection")
    if selection_module_ok then
      -- Pass range information if available (for :'<,'> commands)
      local line1, line2 = nil, nil
      if opts and opts.range and opts.range > 0 then
        line1, line2 = opts.line1, opts.line2
      end
      local sent_successfully = selection_module.send_at_mention_for_visual_selection(line1, line2)
      if sent_successfully then
        -- Exit any potential visual mode (for consistency)
        pcall(function()
          if vim.api and vim.api.nvim_feedkeys then
            local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
            vim.api.nvim_feedkeys(esc, "i", true)
          end
        end)
      end
    else
      logger.error("command", "ClaudeCodeSend: Failed to load selection module.")
    end
  end

  local function handle_send_visual(visual_data, opts)
    -- Check if we're in a tree buffer first
    local current_ft = (vim.bo and vim.bo.filetype) or ""
    local current_bufname = (vim.api and vim.api.nvim_buf_get_name and vim.api.nvim_buf_get_name(0)) or ""

    local is_tree_buffer = current_ft == "NvimTree"
      or current_ft == "neo-tree"
      or current_ft == "oil"
      or current_ft == "minifiles"
      or current_ft == "netrw"
      or string.match(current_bufname, "neo%-tree")
      or string.match(current_bufname, "NvimTree")
      or string.match(current_bufname, "minifiles://")

    if is_tree_buffer then
      local integrations = require("claudecode.integrations")
      local visual_cmd_module = require("claudecode.visual_commands")
      local files, error

      -- For mini.files, try to get the range from visual marks for accuracy
      if current_ft == "minifiles" or string.match(current_bufname, "minifiles://") then
        local start_line = vim.fn.line("'<")
        local end_line = vim.fn.line("'>")

        if start_line > 0 and end_line > 0 and start_line <= end_line then
          files, error = integrations._get_mini_files_selection_with_range(start_line, end_line)
        else
          -- If range invalid, try visual selection fallback (uses pre-captured visual_data)
          files, error = visual_cmd_module.get_files_from_visual_selection(visual_data)
        end
      else
        -- Use visual selection-aware extraction for tree buffers (neo-tree, nvim-tree, oil)
        files, error = visual_cmd_module.get_files_from_visual_selection(visual_data)
        if (not files or #files == 0) and not error then
          -- Fallback: try generic selection if visual data was unavailable
          files, error = integrations.get_selected_files_from_tree()
        end
      end

      if error then
        logger.error("command", "ClaudeCodeSend_visual->TreeAdd: " .. error)
        return
      end

      if not files or #files == 0 then
        logger.warn("command", "ClaudeCodeSend_visual->TreeAdd: No files selected")
        return
      end

      add_paths_to_claude(files, { context = "ClaudeCodeSend_visual->TreeAdd" })
      return
    end

    -- Fall back to old visual selection logic for non-tree buffers
    if visual_data then
      local visual_commands = require("claudecode.visual_commands")
      local files, error = visual_commands.get_files_from_visual_selection(visual_data)

      if not error and files and #files > 0 then
        local success_count = add_paths_to_claude(files, {
          delay = 10,
          context = "ClaudeCodeSend_visual",
          show_summary = false,
        })
        if success_count > 0 then
          local message = success_count == 1 and "Added 1 file to Claude context from visual selection"
            or string.format("Added %d files to Claude context from visual selection", success_count)
          logger.debug("command", message)
        end
        return
      end
    end

    -- Handle regular text selection using range from visual mode
    local selection_module_ok, selection_module = pcall(require, "claudecode.selection")
    if not selection_module_ok then
      return
    end

    -- Use the marks left by visual mode instead of trying to get current visual selection
    local line1, line2 = vim.fn.line("'<"), vim.fn.line("'>")
    if line1 and line2 and line1 > 0 and line2 > 0 then
      selection_module.send_at_mention_for_visual_selection(line1, line2)
    else
      selection_module.send_at_mention_for_visual_selection()
    end
  end

  local visual_commands = require("claudecode.visual_commands")
  local unified_send_handler = visual_commands.create_visual_command_wrapper(handle_send_normal, handle_send_visual)

  vim.api.nvim_create_user_command("ClaudeCodeSend", unified_send_handler, {
    desc = "Send current visual selection as an at_mention to Claude Code (supports tree visual selection)",
    range = true,
  })

  local function handle_tree_add_normal()
    if not M.state.server then
      logger.error("command", "ClaudeCodeTreeAdd: Claude Code integration is not running.")
      return
    end

    local integrations = require("claudecode.integrations")
    local files, error = integrations.get_selected_files_from_tree()

    if error then
      logger.error("command", "ClaudeCodeTreeAdd: " .. error)
      return
    end

    if not files or #files == 0 then
      logger.warn("command", "ClaudeCodeTreeAdd: No files selected")
      return
    end

    -- Use connection-aware broadcasting for each file
    local success_count = 0
    local total_count = #files

    for _, file_path in ipairs(files) do
      local success, error_msg = M.send_at_mention(file_path, nil, nil, "ClaudeCodeTreeAdd")
      if success then
        success_count = success_count + 1
      else
        logger.error(
          "command",
          "ClaudeCodeTreeAdd: Failed to add file: " .. file_path .. " - " .. (error_msg or "unknown error")
        )
      end
    end

    if success_count == 0 then
      logger.error("command", "ClaudeCodeTreeAdd: Failed to add any files")
    elseif success_count < total_count then
      local message = string.format("Added %d/%d files to Claude context", success_count, total_count)
      logger.debug("command", message)
    else
      local message = success_count == 1 and "Added 1 file to Claude context"
        or string.format("Added %d files to Claude context", success_count)
      logger.debug("command", message)
    end
  end

  local function handle_tree_add_visual(visual_data)
    if not M.state.server then
      logger.error("command", "ClaudeCodeTreeAdd_visual: Claude Code integration is not running.")
      return
    end

    local visual_cmd_module = require("claudecode.visual_commands")
    local files, error = visual_cmd_module.get_files_from_visual_selection(visual_data)

    if error then
      logger.error("command", "ClaudeCodeTreeAdd_visual: " .. error)
      return
    end

    if not files or #files == 0 then
      logger.warn("command", "ClaudeCodeTreeAdd_visual: No files selected in visual range")
      return
    end

    -- Use connection-aware broadcasting for each file
    local success_count = 0
    local total_count = #files

    for _, file_path in ipairs(files) do
      local success, error_msg = M.send_at_mention(file_path, nil, nil, "ClaudeCodeTreeAdd_visual")
      if success then
        success_count = success_count + 1
      else
        logger.error(
          "command",
          "ClaudeCodeTreeAdd_visual: Failed to add file: " .. file_path .. " - " .. (error_msg or "unknown error")
        )
      end
    end

    if success_count > 0 then
      local message = success_count == 1 and "Added 1 file to Claude context from visual selection"
        or string.format("Added %d files to Claude context from visual selection", success_count)
      logger.debug("command", message)

      if success_count < total_count then
        logger.warn("command", string.format("Added %d/%d files from visual selection", success_count, total_count))
      end
    else
      logger.error("command", "ClaudeCodeTreeAdd_visual: Failed to add any files from visual selection")
    end
  end

  local unified_tree_add_handler =
    visual_commands.create_visual_command_wrapper(handle_tree_add_normal, handle_tree_add_visual)

  vim.api.nvim_create_user_command("ClaudeCodeTreeAdd", unified_tree_add_handler, {
    desc = "Add selected file(s) from tree explorer to Claude Code context (supports visual selection)",
  })

  vim.api.nvim_create_user_command("ClaudeCodeAdd", function(opts)
    if not M.state.server then
      logger.error("command", "ClaudeCodeAdd: Claude Code integration is not running.")
      return
    end

    if not opts.args or opts.args == "" then
      logger.error("command", "ClaudeCodeAdd: No file path provided")
      return
    end

    local args = vim.split(opts.args, "%s+")
    local file_path = args[1]
    local start_line = args[2] and tonumber(args[2]) or nil
    local end_line = args[3] and tonumber(args[3]) or nil

    if #args > 3 then
      logger.error(
        "command",
        "ClaudeCodeAdd: Too many arguments. Usage: ClaudeCodeAdd <file-path> [start-line] [end-line]"
      )
      return
    end

    if args[2] and not start_line then
      logger.error("command", "ClaudeCodeAdd: Invalid start line number: " .. args[2])
      return
    end

    if args[3] and not end_line then
      logger.error("command", "ClaudeCodeAdd: Invalid end line number: " .. args[3])
      return
    end

    if start_line and start_line < 1 then
      logger.error("command", "ClaudeCodeAdd: Start line must be positive: " .. start_line)
      return
    end

    if end_line and end_line < 1 then
      logger.error("command", "ClaudeCodeAdd: End line must be positive: " .. end_line)
      return
    end

    if start_line and end_line and start_line > end_line then
      logger.error(
        "command",
        "ClaudeCodeAdd: Start line (" .. start_line .. ") must be <= end line (" .. end_line .. ")"
      )
      return
    end

    file_path = vim.fn.expand(file_path)
    if vim.fn.filereadable(file_path) == 0 and vim.fn.isdirectory(file_path) == 0 then
      logger.error("command", "ClaudeCodeAdd: File or directory does not exist: " .. file_path)
      return
    end

    local claude_start_line = start_line and (start_line - 1) or nil
    local claude_end_line = end_line and (end_line - 1) or nil

    local success, error_msg = M.send_at_mention(file_path, claude_start_line, claude_end_line, "ClaudeCodeAdd")
    if not success then
      logger.error("command", "ClaudeCodeAdd: " .. (error_msg or "Failed to add file"))
    else
      local message = "ClaudeCodeAdd: Successfully added " .. file_path
      if start_line or end_line then
        if start_line and end_line then
          message = message .. " (lines " .. start_line .. "-" .. end_line .. ")"
        elseif start_line then
          message = message .. " (from line " .. start_line .. ")"
        end
      end
      logger.debug("command", message)
    end
  end, {
    nargs = "+",
    complete = "file",
    desc = "Add specified file or directory to Claude Code context with optional line range",
  })

  local terminal_ok, terminal = pcall(require, "claudecode.terminal")
  if terminal_ok then
    vim.api.nvim_create_user_command("ClaudeCode", function(opts)
      local current_mode = vim.fn.mode()
      if current_mode == "v" or current_mode == "V" or current_mode == "\22" then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
      end
      local cmd_args = opts.args and opts.args ~= "" and opts.args or nil
      terminal.simple_toggle({}, cmd_args)
    end, {
      nargs = "*",
      desc = "Toggle the Claude Code terminal window (simple show/hide) with optional arguments",
    })

    vim.api.nvim_create_user_command("ClaudeCodeFocus", function(opts)
      local current_mode = vim.fn.mode()
      if current_mode == "v" or current_mode == "V" or current_mode == "\22" then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
      end
      local cmd_args = opts.args and opts.args ~= "" and opts.args or nil
      terminal.focus_toggle({}, cmd_args)
    end, {
      nargs = "*",
      desc = "Smart focus/toggle Claude Code terminal (switches to terminal if not focused, hides if focused)",
    })

    vim.api.nvim_create_user_command("ClaudeCodeOpen", function(opts)
      local cmd_args = opts.args and opts.args ~= "" and opts.args or nil
      terminal.open({}, cmd_args)
    end, {
      nargs = "*",
      desc = "Open the Claude Code terminal window with optional arguments",
    })

    vim.api.nvim_create_user_command("ClaudeCodeClose", function()
      terminal.close()
    end, {
      desc = "Close the Claude Code terminal window",
    })
  else
    logger.error(
      "init",
      "Terminal module not found. Terminal commands (ClaudeCode, ClaudeCodeOpen, ClaudeCodeClose) not registered."
    )
  end

  -- Diff management commands
  vim.api.nvim_create_user_command("ClaudeCodeDiffAccept", function()
    local diff = require("claudecode.diff")
    diff.accept_current_diff()
  end, {
    desc = "Accept the current diff changes",
  })

  vim.api.nvim_create_user_command("ClaudeCodeDiffDeny", function()
    local diff = require("claudecode.diff")
    diff.deny_current_diff()
  end, {
    desc = "Deny/reject the current diff changes",
  })

  vim.api.nvim_create_user_command("ClaudeCodeSelectModel", function(opts)
    local cmd_args = opts.args and opts.args ~= "" and opts.args or nil
    M.open_with_model(cmd_args)
  end, {
    nargs = "*",
    desc = "Select and open Claude terminal with chosen model and optional arguments",
  })
end

M.open_with_model = function(additional_args)
  local models = M.state.config.models

  if not models or #models == 0 then
    logger.error("command", "No models configured for selection")
    return
  end

  vim.ui.select(models, {
    prompt = "Select Claude model:",
    format_item = function(item)
      return item.name
    end,
  }, function(choice)
    if not choice then
      return -- User cancelled
    end

    if not choice.value or type(choice.value) ~= "string" then
      logger.error("command", "Invalid model value selected")
      return
    end

    local model_arg = "--model " .. choice.value
    local final_args = additional_args and (model_arg .. " " .. additional_args) or model_arg
    vim.cmd("ClaudeCode " .. final_args)
  end)
end

---Get version information
---@return { version: string, major: integer, minor: integer, patch: integer, prerelease: string|nil }
function M.get_version()
  return {
    version = M.version:string(),
    major = M.version.major,
    minor = M.version.minor,
    patch = M.version.patch,
    prerelease = M.version.prerelease,
  }
end

---Format file path for at mention (exposed for testing)
---@param file_path string The file path to format
---@return string formatted_path The formatted path
---@return boolean is_directory Whether the path is a directory
function M._format_path_for_at_mention(file_path)
  -- Input validation
  if not file_path or type(file_path) ~= "string" or file_path == "" then
    error("format_path_for_at_mention: file_path must be a non-empty string")
  end

  -- Only check path existence in production (not tests)
  -- This allows tests to work with mock paths while still providing validation in real usage
  if not package.loaded["busted"] then
    if vim.fn.filereadable(file_path) == 0 and vim.fn.isdirectory(file_path) == 0 then
      error("format_path_for_at_mention: path does not exist: " .. file_path)
    end
  end

  local is_directory = vim.fn.isdirectory(file_path) == 1
  local formatted_path = file_path

  if is_directory then
    local cwd = vim.fn.getcwd()
    if string.find(file_path, cwd, 1, true) == 1 then
      local relative_path = string.sub(file_path, #cwd + 2)
      if relative_path ~= "" then
        formatted_path = relative_path
      else
        formatted_path = "./"
      end
    end
    if not string.match(formatted_path, "/$") then
      formatted_path = formatted_path .. "/"
    end
  else
    local cwd = vim.fn.getcwd()
    if string.find(file_path, cwd, 1, true) == 1 then
      local relative_path = string.sub(file_path, #cwd + 2)
      if relative_path ~= "" then
        formatted_path = relative_path
      end
    end
  end

  return formatted_path, is_directory
end

---Test helper functions (exposed for testing)
function M._broadcast_at_mention(file_path, start_line, end_line)
  if not M.state.server then
    return false, "Claude Code integration is not running"
  end

  -- Safely format the path and handle validation errors
  local formatted_path, is_directory
  local format_success, format_result, is_dir_result = pcall(M._format_path_for_at_mention, file_path)
  if not format_success then
    return false, format_result -- format_result contains the error message
  end
  formatted_path, is_directory = format_result, is_dir_result

  if is_directory and (start_line or end_line) then
    logger.debug("command", "Line numbers ignored for directory: " .. formatted_path)
    start_line = nil
    end_line = nil
  end

  local params = {
    filePath = formatted_path,
    lineStart = start_line,
    lineEnd = end_line,
  }

  -- For tests or when explicitly configured, broadcast immediately without queuing
  if
    (M.state.config and M.state.config.disable_broadcast_debouncing)
    or (package.loaded["busted"] and not (M.state.config and M.state.config.enable_broadcast_debouncing_in_tests))
  then
    local broadcast_success = M.state.server.broadcast("at_mentioned", params)
    if broadcast_success then
      return true, nil
    else
      local error_msg = "Failed to broadcast " .. (is_directory and "directory" or "file") .. " " .. formatted_path
      logger.error("command", error_msg)
      return false, error_msg
    end
  end

  -- Use mention queue system for debounced broadcasting
  queue_mention(formatted_path, start_line, end_line)

  -- Always return success since we're queuing the message
  -- The actual broadcast result will be logged in the queue processing
  return true, nil
end

function M._add_paths_to_claude(file_paths, options)
  options = options or {}
  local delay = options.delay or 0
  local show_summary = options.show_summary ~= false
  local context = options.context or "command"
  local batch_size = options.batch_size or 10
  local max_files = options.max_files or 100

  if not file_paths or #file_paths == 0 then
    return 0, 0
  end

  if #file_paths > max_files then
    logger.warn(context, string.format("Too many files selected (%d), limiting to %d", #file_paths, max_files))
    local limited_paths = {}
    for i = 1, max_files do
      limited_paths[i] = file_paths[i]
    end
    file_paths = limited_paths
  end

  local success_count = 0
  local total_count = #file_paths

  if delay > 0 then
    local function send_batch(start_index)
      if start_index > total_count then
        if show_summary then
          local message = success_count == 1 and "Added 1 file to Claude context"
            or string.format("Added %d files to Claude context", success_count)
          if total_count > success_count then
            message = message .. string.format(" (%d failed)", total_count - success_count)
          end

          if total_count > success_count then
            if success_count > 0 then
              logger.warn(context, message)
            else
              logger.error(context, message)
            end
          elseif success_count > 0 then
            logger.info(context, message)
          else
            logger.debug(context, message)
          end
        end
        return
      end

      -- Process a batch of files
      local end_index = math.min(start_index + batch_size - 1, total_count)
      local batch_success = 0

      for i = start_index, end_index do
        local file_path = file_paths[i]
        local success, error_msg = M._broadcast_at_mention(file_path)
        if success then
          success_count = success_count + 1
          batch_success = batch_success + 1
        else
          logger.error(context, "Failed to add file: " .. file_path .. " - " .. (error_msg or "unknown error"))
        end
      end

      logger.debug(
        context,
        string.format(
          "Processed batch %d-%d: %d/%d successful",
          start_index,
          end_index,
          batch_success,
          end_index - start_index + 1
        )
      )

      if end_index < total_count then
        vim.defer_fn(function()
          send_batch(end_index + 1)
        end, delay)
      else
        if show_summary then
          local message = success_count == 1 and "Added 1 file to Claude context"
            or string.format("Added %d files to Claude context", success_count)
          if total_count > success_count then
            message = message .. string.format(" (%d failed)", total_count - success_count)
          end

          if total_count > success_count then
            if success_count > 0 then
              logger.warn(context, message)
            else
              logger.error(context, message)
            end
          elseif success_count > 0 then
            logger.info(context, message)
          else
            logger.debug(context, message)
          end
        end
      end
    end

    send_batch(1)
  else
    local progress_interval = math.max(1, math.floor(total_count / 10))

    for i, file_path in ipairs(file_paths) do
      local success, error_msg = M._broadcast_at_mention(file_path)
      if success then
        success_count = success_count + 1
      else
        logger.error(context, "Failed to add file: " .. file_path .. " - " .. (error_msg or "unknown error"))
      end

      if total_count > 20 and i % progress_interval == 0 then
        logger.debug(
          context,
          string.format("Progress: %d/%d files processed (%d successful)", i, total_count, success_count)
        )
      end
    end

    if show_summary then
      local message = success_count == 1 and "Added 1 file to Claude context"
        or string.format("Added %d files to Claude context", success_count)
      if total_count > success_count then
        message = message .. string.format(" (%d failed)", total_count - success_count)
      end

      if total_count > success_count then
        if success_count > 0 then
          logger.warn(context, message)
        else
          logger.error(context, message)
        end
      elseif success_count > 0 then
        logger.info(context, message)
      else
        logger.debug(context, message)
      end
    end
  end

  return success_count, total_count
end

return M

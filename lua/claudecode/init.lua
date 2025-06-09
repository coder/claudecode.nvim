---@brief [[
--- Claude Code Neovim Integration
--- This plugin integrates Claude Code CLI with Neovim, enabling
--- seamless AI-assisted coding experiences directly in Neovim.
---@brief ]]

--- @module 'claudecode'
local M = {}

local logger = require("claudecode.logger")

--- @class ClaudeCode.Version
--- @field major integer Major version number
--- @field minor integer Minor version number
--- @field patch integer Patch version number
--- @field prerelease string|nil Prerelease identifier (e.g., "alpha", "beta")
--- @field string fun(self: ClaudeCode.Version):string Returns the formatted version string

--- The current version of the plugin.
--- @type ClaudeCode.Version
M.version = {
  major = 0,
  minor = 1,
  patch = 0,
  prerelease = "alpha",
  string = function(self)
    local version = string.format("%d.%d.%d", self.major, self.minor, self.patch)
    if self.prerelease then
      version = version .. "-" .. self.prerelease
    end
    return version
  end,
}

--- @class ClaudeCode.Config
--- @field port_range {min: integer, max: integer} Port range for WebSocket server.
--- @field auto_start boolean Auto-start WebSocket server on Neovim startup.
--- @field terminal_cmd string|nil Custom terminal command to use when launching Claude.
--- @field log_level "trace"|"debug"|"info"|"warn"|"error" Log level.
--- @field track_selection boolean Enable sending selection updates to Claude.
--- @field visual_demotion_delay_ms number Milliseconds to wait before demoting a visual selection.
--- @field diff_opts { auto_close_on_accept: boolean, show_diff_stats: boolean, vertical_split: boolean, open_in_current_tab: boolean } Options for the diff provider.

--- @type ClaudeCode.Config
local default_config = {
  port_range = { min = 10000, max = 65535 },
  auto_start = true,
  terminal_cmd = nil,
  log_level = "info",
  track_selection = true,
  visual_demotion_delay_ms = 50, -- Reduced from 200ms for better responsiveness in tree navigation
  diff_opts = {
    auto_close_on_accept = true,
    show_diff_stats = true,
    vertical_split = true,
    open_in_current_tab = false,
  },
}

--- @class ClaudeCode.State
--- @field config ClaudeCode.Config The current plugin configuration.
--- @field server table|nil The WebSocket server instance.
--- @field port number|nil The port the server is running on.
--- @field initialized boolean Whether the plugin has been initialized.

--- @type ClaudeCode.State
M.state = {
  config = vim.deepcopy(default_config),
  server = nil,
  port = nil,
  initialized = false,
}

---@alias ClaudeCode.TerminalOpts { \
---  split_side?: "left"|"right", \
---  split_width_percentage?: number, \
---  provider?: "snacks"|"native", \
---  show_native_term_exit_tip?: boolean }
---
---@alias ClaudeCode.SetupOpts { \
---  terminal?: ClaudeCode.TerminalOpts }
---
--- Set up the plugin with user configuration
---@param opts ClaudeCode.SetupOpts|nil Optional configuration table to override defaults.
---@return table The plugin module
function M.setup(opts)
  opts = opts or {}

  local terminal_opts = nil
  if opts.terminal then
    terminal_opts = opts.terminal
    opts.terminal = nil -- Remove from main opts to avoid polluting M.state.config
  end

  local config = require("claudecode.config")
  M.state.config = config.apply(opts)
  -- vim.g.claudecode_user_config is no longer needed as config values are passed directly.

  logger.setup(M.state.config)

  -- Setup terminal module: always try to call setup to pass terminal_cmd,
  -- even if terminal_opts (for split_side etc.) are not provided.
  local terminal_setup_ok, terminal_module = pcall(require, "claudecode.terminal")
  if terminal_setup_ok then
    -- terminal_opts might be nil if user only configured top-level terminal_cmd
    -- and not specific terminal appearance options.
    -- The terminal.setup function handles nil for its first argument.
    terminal_module.setup(terminal_opts, M.state.config.terminal_cmd)
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
      end
    end,
    desc = "Automatically stop Claude Code integration when exiting Neovim",
  })

  M.state.initialized = true
  return M
end

--- Start the Claude Code integration
---@param show_startup_notification? boolean Whether to show a notification upon successful startup (defaults to true)
---@return boolean success Whether the operation was successful
---@return number|string port_or_error The WebSocket port if successful, or error message if failed
function M.start(show_startup_notification)
  if show_startup_notification == nil then
    show_startup_notification = true
  end
  if M.state.server then
    local msg = "Claude Code integration is already running on port " .. tostring(M.state.port)
    vim.notify(msg, vim.log.levels.WARN)
    return false, "Already running"
  end

  local server = require("claudecode.server.init")
  local success, result = server.start(M.state.config)

  if not success then
    vim.notify("Failed to start Claude Code integration: " .. result, vim.log.levels.ERROR)
    return false, result
  end

  M.state.server = server
  M.state.port = tonumber(result)

  local lockfile = require("claudecode.lockfile")
  local lock_success, lock_result = lockfile.create(M.state.port)

  if not lock_success then
    server.stop()
    M.state.server = nil
    M.state.port = nil

    vim.notify("Failed to create lock file: " .. lock_result, vim.log.levels.ERROR)
    return false, lock_result
  end

  if M.state.config.track_selection then
    local selection = require("claudecode.selection")
    selection.enable(M.state.server, M.state.config.visual_demotion_delay_ms)
  end

  if show_startup_notification then
    vim.notify("Claude Code integration started on port " .. tostring(M.state.port), vim.log.levels.INFO)
  end

  return true, M.state.port
end

--- Stop the Claude Code integration
---@return boolean success Whether the operation was successful
---@return string? error Error message if operation failed
function M.stop()
  if not M.state.server then
    vim.notify("Claude Code integration is not running", vim.log.levels.WARN)
    return false, "Not running"
  end

  local lockfile = require("claudecode.lockfile")
  local lock_success, lock_error = lockfile.remove(M.state.port)

  if not lock_success then
    vim.notify("Failed to remove lock file: " .. lock_error, vim.log.levels.WARN)
    -- Continue with shutdown even if lock file removal fails
  end

  if M.state.config.track_selection then
    local selection = require("claudecode.selection")
    selection.disable()
  end

  local success, error = M.state.server.stop()

  if not success then
    vim.notify("Failed to stop Claude Code integration: " .. error, vim.log.levels.ERROR)
    return false, error
  end

  M.state.server = nil
  M.state.port = nil

  vim.notify("Claude Code integration stopped", vim.log.levels.INFO)

  return true
end

--- Set up user commands
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
      vim.notify("Claude Code integration is running on port " .. tostring(M.state.port), vim.log.levels.INFO)
    else
      vim.notify("Claude Code integration is not running", vim.log.levels.INFO)
    end
  end, {
    desc = "Show Claude Code integration status",
  })

  local function format_path_for_at_mention(file_path)
    return M._format_path_for_at_mention(file_path)
  end

  ---@param file_path string The file path to broadcast
  ---@return boolean success Whether the broadcast was successful
  ---@return string|nil error Error message if broadcast failed
  local function broadcast_at_mention(file_path, start_line, end_line)
    if not M.state.server then
      return false, "Claude Code integration is not running"
    end

    local formatted_path, is_directory
    local format_success, format_result, is_dir_result = pcall(format_path_for_at_mention, file_path)
    if not format_success then
      return false, format_result
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

    local broadcast_success = M.state.server.broadcast("at_mentioned", params)
    if broadcast_success then
      if logger.is_level_enabled and logger.is_level_enabled("debug") then
        local message = "Broadcast success: Added " .. (is_directory and "directory" or "file") .. " " .. formatted_path
        if not is_directory and (start_line or end_line) then
          local range_info = ""
          if start_line and end_line then
            range_info = " (lines " .. start_line .. "-" .. end_line .. ")"
          elseif start_line then
            range_info = " (from line " .. start_line .. ")"
          end
          message = message .. range_info
        end
        logger.debug("command", message)
      elseif not logger.is_level_enabled then
        logger.debug(
          "command",
          "Broadcast success: Added " .. (is_directory and "directory" or "file") .. " " .. formatted_path
        )
      end
      return true, nil
    else
      local error_msg = "Failed to broadcast " .. (is_directory and "directory" or "file") .. " " .. formatted_path
      logger.error("command", error_msg)
      return false, error_msg
    end
  end

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
            local level = vim.log.levels.INFO

            if total_count > success_count then
              message = message .. string.format(" (%d failed)", total_count - success_count)
              level = success_count > 0 and vim.log.levels.WARN or vim.log.levels.ERROR
            end

            if success_count > 0 or total_count > success_count then
              vim.notify(message, level)
            end
            logger.debug(context, message)
          end
          return
        end

        local file_path = file_paths[index]
        local success, error_msg = broadcast_at_mention(file_path)
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
            local level = vim.log.levels.INFO

            if total_count > success_count then
              message = message .. string.format(" (%d failed)", total_count - success_count)
              level = success_count > 0 and vim.log.levels.WARN or vim.log.levels.ERROR
            end

            if success_count > 0 or total_count > success_count then
              vim.notify(message, level)
            end
            logger.debug(context, message)
          end
        end
      end

      send_files_sequentially(1)
    else
      for _, file_path in ipairs(file_paths) do
        local success, error_msg = broadcast_at_mention(file_path)
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
    if not M.state.server then
      logger.error("command", "ClaudeCodeSend: Claude Code integration is not running.")
      vim.notify("Claude Code integration is not running", vim.log.levels.ERROR)
      return
    end

    local current_ft = vim.bo.filetype
    local current_bufname = vim.api.nvim_buf_get_name(0)

    local is_tree_buffer = current_ft == "NvimTree"
      or current_ft == "neo-tree"
      or string.match(current_bufname, "neo%-tree")
      or string.match(current_bufname, "NvimTree")

    if is_tree_buffer then
      local integrations = require("claudecode.integrations")
      local files, error = integrations.get_selected_files_from_tree()

      if error then
        logger.warn("command", "ClaudeCodeSend->TreeAdd: " .. error)
        vim.notify("Tree integration error: " .. error, vim.log.levels.ERROR)
        return
      end

      if not files or #files == 0 then
        logger.warn("command", "ClaudeCodeSend->TreeAdd: No files selected")
        vim.notify("No files selected in tree explorer", vim.log.levels.WARN)
        return
      end

      add_paths_to_claude(files, { context = "ClaudeCodeSend->TreeAdd" })

      return
    end

    local selection_module_ok, selection_module = pcall(require, "claudecode.selection")
    if selection_module_ok then
      local sent_successfully = selection_module.send_at_mention_for_visual_selection()
      if sent_successfully then
        local terminal_ok, terminal = pcall(require, "claudecode.terminal")
        if terminal_ok then
          terminal.open({})
          logger.debug("command", "ClaudeCodeSend: Focused Claude Code terminal after selection send.")
        else
          logger.warn("command", "ClaudeCodeSend: Failed to load terminal module for focusing.")
        end
      end
    else
      logger.error("command", "ClaudeCodeSend: Failed to load selection module.")
      vim.notify("Failed to send selection: selection module not loaded.", vim.log.levels.ERROR)
    end
  end

  local function handle_send_visual(visual_data, opts)
    if not M.state.server then
      logger.error("command", "ClaudeCodeSend_visual: Claude Code integration is not running.")
      return
    end

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

          local terminal_ok, terminal = pcall(require, "claudecode.terminal")
          if terminal_ok then
            terminal.open({})
          end
        end
        return
      end
    end
    local selection_module_ok, selection_module = pcall(require, "claudecode.selection")
    if selection_module_ok then
      local sent_successfully = selection_module.send_at_mention_for_visual_selection()
      if sent_successfully then
        local terminal_ok, terminal = pcall(require, "claudecode.terminal")
        if terminal_ok then
          terminal.open({})
        end
      end
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
      logger.warn("command", "ClaudeCodeTreeAdd: " .. error)
      return
    end

    if not files or #files == 0 then
      logger.warn("command", "ClaudeCodeTreeAdd: No files selected")
      return
    end

    local success_count = add_paths_to_claude(files, { context = "ClaudeCodeTreeAdd" })

    if success_count == 0 then
      logger.error("command", "ClaudeCodeTreeAdd: Failed to add any files")
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
      logger.warn("command", "ClaudeCodeTreeAdd_visual: " .. error)
      return
    end

    if not files or #files == 0 then
      logger.warn("command", "ClaudeCodeTreeAdd_visual: No files selected in visual range")
      return
    end

    local success_count = add_paths_to_claude(files, {
      delay = 10,
      context = "ClaudeCodeTreeAdd_visual",
      show_summary = false,
    })
    if success_count > 0 then
      local message = success_count == 1 and "Added 1 file to Claude context from visual selection"
        or string.format("Added %d files to Claude context from visual selection", success_count)
      logger.debug("command", message)
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

    local success, error_msg = broadcast_at_mention(file_path, claude_start_line, claude_end_line)
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
    vim.api.nvim_create_user_command("ClaudeCode", function(_opts)
      local current_mode = vim.fn.mode()
      if current_mode == "v" or current_mode == "V" or current_mode == "\22" then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
      end
      terminal.toggle({})
    end, {
      nargs = "?",
      desc = "Toggle the Claude Code terminal window",
    })

    vim.api.nvim_create_user_command("ClaudeCodeOpen", function(_opts)
      terminal.open({})
    end, {
      nargs = "?",
      desc = "Open the Claude Code terminal window",
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
end

--- Get version information
---@return table Version information
function M.get_version()
  return {
    version = M.version:string(),
    major = M.version.major,
    minor = M.version.minor,
    patch = M.version.patch,
    prerelease = M.version.prerelease,
  }
end

--- Format file path for at mention (exposed for testing)
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

-- Test helper functions (exposed for testing)
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

  local broadcast_success = M.state.server.broadcast("at_mentioned", params)
  if broadcast_success then
    return true, nil
  else
    local error_msg = "Failed to broadcast " .. (is_directory and "directory" or "file") .. " " .. formatted_path
    logger.error("command", error_msg)
    return false, error_msg
  end
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
    vim.notify(
      string.format("Too many files selected (%d), processing first %d", #file_paths, max_files),
      vim.log.levels.WARN
    )
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
          local level = vim.log.levels.INFO

          if total_count > success_count then
            message = message .. string.format(" (%d failed)", total_count - success_count)
            level = success_count > 0 and vim.log.levels.WARN or vim.log.levels.ERROR
          end

          if success_count > 0 or total_count > success_count then
            vim.notify(message, level)
          end
          logger.debug(context, message)
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
          local level = vim.log.levels.INFO

          if total_count > success_count then
            message = message .. string.format(" (%d failed)", total_count - success_count)
            level = success_count > 0 and vim.log.levels.WARN or vim.log.levels.ERROR
          end

          if success_count > 0 or total_count > success_count then
            vim.notify(message, level)
          end
          logger.debug(context, message)
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
      local level = vim.log.levels.INFO

      if total_count > success_count then
        message = message .. string.format(" (%d failed)", total_count - success_count)
        level = success_count > 0 and vim.log.levels.WARN or vim.log.levels.ERROR
      end

      if success_count > 0 or total_count > success_count then
        vim.notify(message, level)
      end
      logger.debug(context, message)
    end
  end

  return success_count, total_count
end

return M

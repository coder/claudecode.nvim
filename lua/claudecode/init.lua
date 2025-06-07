---@brief [[
--- Claude Code Neovim Integration
--- This plugin integrates Claude Code CLI with Neovim, enabling
--- seamless AI-assisted coding experiences directly in Neovim.
---@brief ]]

--- @module 'claudecode'
local M = {}

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
  visual_demotion_delay_ms = 50,
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

  local logger = require("claudecode.logger")
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
  local logger = require("claudecode.logger")

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

  -- Helper function to format file paths for at mentions
  local function format_path_for_at_mention(file_path)
    local is_directory = vim.fn.isdirectory(file_path) == 1
    local formatted_path = file_path

    -- For directories, convert to relative path and add trailing slash
    if is_directory then
      -- Get current working directory
      local cwd = vim.fn.getcwd()
      -- Convert absolute path to relative if it's under the current working directory
      if string.find(file_path, cwd, 1, true) == 1 then
        local relative_path = string.sub(file_path, #cwd + 2) -- +2 to skip the trailing slash
        if relative_path ~= "" then
          formatted_path = relative_path
        end
      end
      -- Always add trailing slash for directories
      if not string.match(formatted_path, "/$") then
        formatted_path = formatted_path .. "/"
      end
    end

    return formatted_path, is_directory
  end

  -- Create the normal send handler
  local function handle_send_normal(opts)
    if not M.state.server then
      logger.error("command", "ClaudeCodeSend: Claude Code integration is not running.")
      vim.notify("Claude Code integration is not running", vim.log.levels.ERROR)
      return
    end

    -- Check if we're in a tree buffer - if so, delegate to tree integration
    local current_ft = vim.bo.filetype
    local current_bufname = vim.api.nvim_buf_get_name(0)

    -- Check both filetype and buffer name for tree detection
    local is_tree_buffer = current_ft == "NvimTree"
      or current_ft == "neo-tree"
      or string.match(current_bufname, "neo%-tree")
      or string.match(current_bufname, "NvimTree")

    if is_tree_buffer then
      local integrations = require("claudecode.integrations")
      local files, error = integrations.get_selected_files_from_tree()

      if error then
        logger.warn("command", "ClaudeCodeSend->TreeAdd: " .. error)
        return
      end

      if not files or #files == 0 then
        logger.warn("command", "ClaudeCodeSend->TreeAdd: No files selected")
        return
      end

      -- Send each file as an at_mention (full file, no line numbers)
      local success_count = 0
      for _, file_path in ipairs(files) do
        local params = {
          filePath = file_path,
          lineStart = nil, -- No line numbers for full file
          lineEnd = nil, -- No line numbers for full file
        }

        local broadcast_success = M.state.server.broadcast("at_mentioned", params)
        if broadcast_success then
          success_count = success_count + 1
          logger.debug("command", "ClaudeCodeSend->TreeAdd: Added file " .. file_path)
        else
          logger.error("command", "ClaudeCodeSend->TreeAdd: Failed to add file " .. file_path)
        end
      end

      if success_count > 0 then
        local message = success_count == 1 and "Added 1 file to Claude context"
          or string.format("Added %d files to Claude context", success_count)
        logger.debug("command", message) -- Use debug level to avoid popup
      else
        logger.error("command", "ClaudeCodeSend->TreeAdd: Failed to add any files")
      end

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

  -- Create the visual send handler (processes visual selection after mode exit)
  local function handle_send_visual(visual_data, opts)
    if not M.state.server then
      logger.error("command", "ClaudeCodeSend_visual: Claude Code integration is not running.")
      return
    end

    -- Try tree visual selection first using captured data
    if visual_data then
      local visual_commands = require("claudecode.visual_commands")
      local files, error = visual_commands.get_files_from_visual_selection(visual_data)

      if not error and files and #files > 0 then
        local file_success_count = 0

        -- Send files with a small delay between each to ensure Claude processes them all
        local function send_files_sequentially(index)
          if index > #files then
            -- All files sent, show summary and focus terminal
            if file_success_count > 0 then
              local message = file_success_count == 1 and "Added 1 file to Claude context from visual selection"
                or string.format("Added %d files to Claude context from visual selection", file_success_count)
              logger.debug("command", message)

              local terminal_ok, terminal = pcall(require, "claudecode.terminal")
              if terminal_ok then
                terminal.open({})
              end
            end
            return
          end

          local file_path = files[index]
          local formatted_path, is_directory = format_path_for_at_mention(file_path)

          local params = {
            filePath = formatted_path,
            lineStart = nil, -- No line numbers for full file
            lineEnd = nil, -- No line numbers for full file
          }

          local broadcast_success = M.state.server.broadcast("at_mentioned", params)
          if broadcast_success then
            file_success_count = file_success_count + 1
            logger.debug(
              "command",
              "ClaudeCodeSend_visual: Added " .. (is_directory and "directory" or "file") .. " " .. formatted_path
            )
          end

          -- Schedule next file send with a small delay (10ms)
          vim.defer_fn(function()
            send_files_sequentially(index + 1)
          end, 10)
        end

        -- Start sending files
        send_files_sequentially(1)
        return
      end
      -- No error handling needed - fall back to text visual selection
    end

    -- Fall back to text visual selection
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

  -- Create the unified command that handles both normal and visual modes
  local visual_commands = require("claudecode.visual_commands")
  local unified_send_handler = visual_commands.create_visual_command_wrapper(handle_send_normal, handle_send_visual)

  vim.api.nvim_create_user_command("ClaudeCodeSend", unified_send_handler, {
    desc = "Send current visual selection as an at_mention to Claude Code (supports tree visual selection)",
    range = true, -- Important: This makes the command expect a range (visual selection)
  })

  -- Create the normal tree add handler
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

    -- Send each file/directory as an at_mention (full file, no line numbers)
    local success_count = 0
    for _, file_path in ipairs(files) do
      local formatted_path, is_directory = format_path_for_at_mention(file_path)

      local params = {
        filePath = formatted_path,
        lineStart = nil, -- No line numbers for full file
        lineEnd = nil, -- No line numbers for full file
      }

      local broadcast_success = M.state.server.broadcast("at_mentioned", params)
      if broadcast_success then
        success_count = success_count + 1
        logger.debug(
          "command",
          "ClaudeCodeTreeAdd: Added " .. (is_directory and "directory" or "file") .. " " .. formatted_path
        )
      else
        logger.error(
          "command",
          "ClaudeCodeTreeAdd: Failed to add " .. (is_directory and "directory" or "file") .. " " .. formatted_path
        )
      end
    end

    if success_count > 0 then
      local message = success_count == 1 and "Added 1 file to Claude context"
        or string.format("Added %d files to Claude context", success_count)
      logger.debug("command", message)
    else
      logger.error("command", "ClaudeCodeTreeAdd: Failed to add any files")
    end
  end

  -- Create the visual tree add handler (processes visual selection after mode exit)
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

    -- Send each file as an at_mention (full file, no line numbers)
    local success_count = 0

    -- Send files with a small delay between each to ensure Claude processes them all
    local function send_files_sequentially(index)
      if index > #files then
        -- All files sent, show summary
        if success_count > 0 then
          local message = success_count == 1 and "Added 1 file to Claude context from visual selection"
            or string.format("Added %d files to Claude context from visual selection", success_count)
          logger.debug("command", message)
        else
          logger.error("command", "ClaudeCodeTreeAdd_visual: Failed to add any files from visual selection")
        end
        return
      end

      local file_path = files[index]
      local formatted_path, is_directory = format_path_for_at_mention(file_path)

      local params = {
        filePath = formatted_path,
        lineStart = nil, -- No line numbers for full file
        lineEnd = nil, -- No line numbers for full file
      }

      local broadcast_success = M.state.server.broadcast("at_mentioned", params)
      if broadcast_success then
        success_count = success_count + 1
        logger.debug(
          "command",
          "ClaudeCodeTreeAdd_visual: Added " .. (is_directory and "directory" or "file") .. " " .. formatted_path
        )
      else
        logger.error(
          "command",
          "ClaudeCodeTreeAdd_visual: Failed to add "
            .. (is_directory and "directory" or "file")
            .. " "
            .. formatted_path
        )
      end

      -- Schedule next file send with a small delay (10ms)
      vim.defer_fn(function()
        send_files_sequentially(index + 1)
      end, 10)
    end

    -- Start sending files
    send_files_sequentially(1)
  end

  -- Create the unified command that handles both normal and visual modes
  local unified_tree_add_handler =
    visual_commands.create_visual_command_wrapper(handle_tree_add_normal, handle_tree_add_visual)

  vim.api.nvim_create_user_command("ClaudeCodeTreeAdd", unified_tree_add_handler, {
    desc = "Add selected file(s) from tree explorer to Claude Code context (supports visual selection)",
  })

  local terminal_ok, terminal = pcall(require, "claudecode.terminal")
  if terminal_ok then
    vim.api.nvim_create_user_command("ClaudeCode", function(_opts)
      local current_mode = vim.fn.mode()
      if current_mode == "v" or current_mode == "V" or current_mode == "\22" then -- \22 is CTRL-V (blockwise visual mode)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
      end
      terminal.toggle({}) -- `opts.fargs` can be used for future enhancements.
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

return M

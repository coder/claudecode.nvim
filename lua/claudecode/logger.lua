---@brief Centralized logger for Claude Code Neovim integration.
-- Provides level-based logging.
---@module 'claudecode.logger'
local M = {}

M.levels = {
  ERROR = 1,
  WARN = 2,
  INFO = 3,
  DEBUG = 4,
  TRACE = 5,
}

local level_values = {
  error = M.levels.ERROR,
  warn = M.levels.WARN,
  info = M.levels.INFO,
  debug = M.levels.DEBUG,
  trace = M.levels.TRACE,
}

local current_log_level_value = M.levels.INFO

---Setup the logger module
---@param plugin_config ClaudeCodeConfig The configuration table (e.g., from claudecode.init.state.config).
function M.setup(plugin_config)
  local conf = plugin_config

  if conf and conf.log_level and level_values[conf.log_level] then
    current_log_level_value = level_values[conf.log_level]
  else
    vim.notify(
      "ClaudeCode Logger: Invalid or missing log_level in configuration (received: "
        .. tostring(conf and conf.log_level)
        .. "). Defaulting to INFO.",
      vim.log.levels.WARN
    )
    current_log_level_value = M.levels.INFO
  end
end

local NAME = "[ClaudeCode] "

-- The level word that stays when a line loses its tags. Without colors (a notify plugin, or :messages read through
-- execute()), it is the only sign of an error or a warning. An info line has none.
local SHORT_LEVEL = { [M.levels.ERROR] = "ERROR: ", [M.levels.WARN] = "WARN: " }

---Makes a log line one line no wider than the command line. A line that is too wide loses the component tag and
---keeps a short level word, and loses the plugin name too when it would take half the width. Then it is cut, ending
---in "..." if that fits.
---@param level integer
---@param prefix string "[ClaudeCode] [component] [LEVEL]"
---@param message string
---@return string
local function fit_command_line(level, prefix, message)
  message = message:gsub("%s+", " ")
  local width = vim.v.echospace
  local text = prefix .. " " .. message
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  text = (width >= 2 * #NAME and NAME or "") .. (SHORT_LEVEL[level] or "") .. message
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local ellipsis = width >= 3 and "..." or ""
  local room = math.max(width - #ellipsis, 0)
  local count = room
  local cut = vim.fn.strcharpart(text, 0, count)
  -- A character can take two cells.
  while vim.fn.strdisplaywidth(cut) > room do
    count = count - 1
    cut = vim.fn.strcharpart(text, 0, count)
  end
  return cut .. ellipsis
end

local function log(level, component, message_parts, one_line)
  if level > current_log_level_value then
    return
  end

  local prefix = "[ClaudeCode]"
  if component then
    prefix = prefix .. " [" .. component .. "]"
  end

  local level_name = "UNKNOWN"
  for name, val in pairs(M.levels) do
    if val == level then
      level_name = name
      break
    end
  end
  prefix = prefix .. " [" .. level_name .. "]"

  local message = ""
  for i, part in ipairs(message_parts) do
    if i > 1 then
      message = message .. " "
    end
    if type(part) == "table" or type(part) == "boolean" then
      message = message .. vim.inspect(part)
    else
      message = message .. tostring(part)
    end
  end

  -- Wrap all vim.notify and nvim_echo calls in vim.schedule to avoid
  -- "nvim_echo must not be called in a fast event context" errors
  vim.schedule(function()
    local text = one_line and fit_command_line(level, prefix, message) or prefix .. " " .. message
    if level == M.levels.ERROR then
      vim.notify(text, vim.log.levels.ERROR, { title = "ClaudeCode Error" })
    elseif level == M.levels.WARN then
      vim.notify(text, vim.log.levels.WARN, { title = "ClaudeCode Warning" })
    else
      -- For INFO, DEBUG, TRACE, use nvim_echo to avoid flooding notifications,
      -- to make them appear in :messages
      vim.api.nvim_echo({ { text, "Normal" } }, true, {})
    end
  end)
end

---Error level logging
---@param component string|nil Optional component/module name.
---@param ... any Varargs representing parts of the message.
function M.error(component, ...)
  if type(component) ~= "string" then
    log(M.levels.ERROR, nil, { component, ... })
  else
    log(M.levels.ERROR, component, { ... })
  end
end

---Warn level logging
---@param component string|nil Optional component/module name.
---@param ... any Varargs representing parts of the message.
function M.warn(component, ...)
  if type(component) ~= "string" then
    log(M.levels.WARN, nil, { component, ... })
  else
    log(M.levels.WARN, component, { ... })
  end
end

---Info level logging
---@param component string|nil Optional component/module name.
---@param ... any Varargs representing parts of the message.
function M.info(component, ...)
  if type(component) ~= "string" then
    log(M.levels.INFO, nil, { component, ... })
  else
    log(M.levels.INFO, component, { ... })
  end
end

---Logs a line about an event the user did not start, such as a server callback. A message wider than the command
---line stops Neovim at "Press ENTER" until the user presses a key. Below log_level debug, the line loses its line
---breaks, and a line wider than the command line loses its tags and is cut to that width.
---@param level_name "error"|"warn"|"info"
---@param component string Component/module name
---@param message string
function M.one_line(level_name, component, message)
  local level = level_values[level_name]
  assert(level and level <= M.levels.INFO, "one_line takes error, warn or info, not " .. tostring(level_name))
  log(level, component, { message }, current_log_level_value < M.levels.DEBUG)
end

---Check if a specific log level is enabled
---@param level_name ClaudeCodeLogLevel The level name ("error", "warn", "info", "debug", "trace")
---@return boolean enabled Whether the level is enabled
function M.is_level_enabled(level_name)
  local level_value = level_values[level_name]
  if not level_value then
    return false
  end
  return level_value <= current_log_level_value
end

---Debug level logging
---@param component string|nil Optional component/module name.
---@param ... any Varargs representing parts of the message.
function M.debug(component, ...)
  if type(component) ~= "string" then
    log(M.levels.DEBUG, nil, { component, ... })
  else
    log(M.levels.DEBUG, component, { ... })
  end
end

---Trace level logging
---@param component string|nil Optional component/module name.
---@param ... any Varargs representing parts of the message.
function M.trace(component, ...)
  if type(component) ~= "string" then
    log(M.levels.TRACE, nil, { component, ... })
  else
    log(M.levels.TRACE, component, { ... })
  end
end

return M

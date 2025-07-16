--- Tmux terminal provider for Claude Code.
-- This provider creates tmux panes to run Claude Code in external tmux sessions.
-- @module claudecode.terminal.tmux

--- @type TerminalProvider
local M = {}

local logger = require("claudecode.logger")

local active_pane_id = nil

local function is_in_tmux()
  return vim and vim.env and vim.env.TMUX ~= nil
end

local function get_tmux_pane_width()
  local handle = io.popen("tmux display-message -p '#{window_width}'")
  if not handle then
    return 80
  end
  local result = handle:read("*a")
  handle:close()
  local cleaned = result and result:gsub("%s+", "") or ""
  return tonumber(cleaned) or 80
end

local function calculate_split_size(percentage)
  if not percentage or percentage <= 0 or percentage >= 1 then
    return nil
  end

  local window_width = get_tmux_pane_width()
  return math.floor(window_width * percentage)
end

local function build_split_command(cmd_string, env_table, effective_config)
  local split_cmd = "tmux split-window"

  if effective_config.split_side == "left" then
    split_cmd = split_cmd .. " -bh"
  else
    split_cmd = split_cmd .. " -h"
  end

  local split_size = calculate_split_size(effective_config.split_width_percentage)
  if split_size then
    split_cmd = split_cmd .. " -l " .. split_size
  end

  -- Add environment variables
  if env_table then
    for key, value in pairs(env_table) do
      split_cmd = split_cmd .. " -e '" .. key .. "=" .. value .. "'"
    end
  end

  split_cmd = split_cmd .. " '" .. cmd_string .. "'"

  return split_cmd
end

local function get_active_pane_id()
  if not active_pane_id then
    return nil
  end

  local handle = io.popen("tmux list-panes -F '#{pane_id}' | grep '" .. active_pane_id .. "'")
  if not handle then
    return nil
  end

  local result = handle:read("*a")
  handle:close()

  if result and result:gsub("%s+", "") == active_pane_id then
    return active_pane_id
  end

  active_pane_id = nil
  return nil
end

local function capture_new_pane_id(split_cmd)
  local full_cmd = split_cmd .. " \\; display-message -p '#{pane_id}'"
  local handle = io.popen(full_cmd)
  if not handle then
    return nil
  end

  local result = handle:read("*a")
  handle:close()

  local pane_id = result:gsub("%s+", ""):match("%%(%d+)")
  return pane_id and ("%" .. pane_id) or nil
end

function M.setup(term_config)
  if not is_in_tmux() then
    logger.warn("terminal", "Tmux provider configured but not running in tmux session")
    return
  end

  logger.debug("terminal", "Tmux terminal provider configured")
end

function M.open(cmd_string, env_table, effective_config, focus)
  if not is_in_tmux() then
    logger.error("terminal", "Cannot open tmux pane - not in tmux session")
    return
  end

  if get_active_pane_id() then
    logger.debug("terminal", "Claude tmux pane already exists, focusing existing pane")
    if focus ~= false then
      vim.fn.system("tmux select-pane -t " .. active_pane_id)
    end
    return
  end

  local split_cmd = build_split_command(cmd_string, env_table, effective_config)
  logger.debug("terminal", "Opening tmux pane with command: " .. split_cmd)

  local new_pane_id = capture_new_pane_id(split_cmd)
  if new_pane_id then
    active_pane_id = new_pane_id
    logger.debug("terminal", "Created tmux pane with ID: " .. active_pane_id)

    if focus == false then
      vim.fn.system("tmux last-pane")
    end
  else
    logger.error("terminal", "Failed to create tmux pane")
  end
end

function M.close()
  local pane_id = get_active_pane_id()
  if not pane_id then
    logger.debug("terminal", "No active Claude tmux pane to close")
    return
  end

  vim.fn.system("tmux kill-pane -t " .. pane_id)
  active_pane_id = nil
  logger.debug("terminal", "Closed tmux pane: " .. pane_id)
end

function M.simple_toggle(cmd_string, env_table, effective_config)
  local pane_id = get_active_pane_id()
  if pane_id then
    M.close()
  else
    M.open(cmd_string, env_table, effective_config, true)
  end
end

function M.focus_toggle(cmd_string, env_table, effective_config)
  local pane_id = get_active_pane_id()
  if not pane_id then
    M.open(cmd_string, env_table, effective_config, true)
    return
  end

  local handle = io.popen("tmux display-message -p '#{pane_active}'")
  if not handle then
    return
  end

  local is_active = handle:read("*a"):gsub("%s+", "") == "1"
  handle:close()

  if is_active then
    M.close()
  else
    vim.fn.system("tmux select-pane -t " .. pane_id)
  end
end

function M.toggle(cmd_string, env_table, effective_config)
  M.simple_toggle(cmd_string, env_table, effective_config)
end

function M.get_active_bufnr()
  return nil
end

function M.is_available()
  return is_in_tmux()
end

function M._get_terminal_for_test()
  return {
    pane_id = active_pane_id,
    is_in_tmux = is_in_tmux(),
  }
end

return M

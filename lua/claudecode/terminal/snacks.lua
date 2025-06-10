--- Snacks.nvim terminal provider for Claude Code.
-- @module claudecode.terminal.snacks

--- @type TerminalProvider
local M = {}

local snacks_available, Snacks = pcall(require, "snacks")
local terminal = nil

--- @return boolean
local function is_available()
  return snacks_available and Snacks and Snacks.terminal
end

--- Setup event handlers for terminal instance
--- @param term_instance table The Snacks terminal instance
--- @param config table Configuration options
local function setup_terminal_events(term_instance, config)
  local logger = require("claudecode.logger")

  -- Handle command completion/exit - only if auto_close is enabled
  if config.auto_close then
    term_instance:on("TermClose", function()
      if vim.v.event.status ~= 0 then
        logger.error("terminal", "Claude exited with code " .. vim.v.event.status .. ".\nCheck for any errors.")
      end

      -- Clean up
      terminal = nil
      vim.schedule(function()
        term_instance:close({ buf = true })
        vim.cmd.checktime()
      end)
    end, { buf = true })
  end

  -- Handle buffer deletion
  term_instance:on("BufWipeout", function()
    logger.debug("terminal", "Terminal buffer wiped")
    terminal = nil
  end, { buf = true })
end

--- @param config table
--- @param env_table table
--- @return table
local function build_opts(config, env_table)
  return {
    env = env_table,
    start_insert = true,
    auto_insert = true,
    auto_close = false,
    win = {
      position = config.split_side,
      width = config.split_width_percentage,
      height = 0,
      relative = "editor",
    },
  }
end

function M.setup()
  -- No specific setup needed for Snacks provider
end

--- @param cmd_string string
--- @param env_table table
--- @param config table
function M.open(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  if terminal and terminal:buf_valid() then
    terminal:focus()
    local term_buf_id = terminal.buf
    if term_buf_id and vim.api.nvim_buf_get_option(term_buf_id, "buftype") == "terminal" then
      vim.api.nvim_win_call(terminal.win, function()
        vim.cmd("startinsert")
      end)
    end
    return
  end

  local opts = build_opts(config, env_table)
  local term_instance = Snacks.terminal.open(cmd_string, opts)
  if term_instance and term_instance:buf_valid() then
    setup_terminal_events(term_instance, config)
    terminal = term_instance
  else
    terminal = nil
    local logger = require("claudecode.logger")
    local error_details = {}
    if not term_instance then
      table.insert(error_details, "Snacks.terminal.open() returned nil")
    elseif not term_instance:buf_valid() then
      table.insert(error_details, "terminal instance is invalid")
      if term_instance.buf and not vim.api.nvim_buf_is_valid(term_instance.buf) then
        table.insert(error_details, "buffer is invalid")
      end
      if term_instance.win and not vim.api.nvim_win_is_valid(term_instance.win) then
        table.insert(error_details, "window is invalid")
      end
    end

    local context = string.format("cmd='%s', opts=%s", cmd_string, vim.inspect(opts))
    local error_msg = string.format(
      "Failed to open Claude terminal using Snacks. Details: %s. Context: %s",
      table.concat(error_details, ", "),
      context
    )
    vim.notify(error_msg, vim.log.levels.ERROR)
    logger.debug("terminal", error_msg)
  end
end

function M.close()
  if not is_available() then
    return
  end
  if terminal and terminal:buf_valid() then
    terminal:close()
  end
end

--- @param cmd_string string
--- @param env_table table
--- @param config table
function M.toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")

  -- Terminal exists, is valid, but not visible
  if terminal and terminal:buf_valid() and not terminal.win then
    logger.debug("terminal", "Toggle existing managed Snacks terminal")
    terminal:toggle()
  -- Terminal exists, is valid, and is visible
  elseif terminal and terminal:buf_valid() and terminal.win then
    local claude_term_neovim_win_id = terminal.win
    local current_neovim_win_id = vim.api.nvim_get_current_win()

    -- you're IN it
    if claude_term_neovim_win_id == current_neovim_win_id then
      terminal:toggle()
    -- you're NOT in it
    else
      vim.api.nvim_set_current_win(claude_term_neovim_win_id)
      if terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) then
        if vim.api.nvim_buf_get_option(terminal.buf, "buftype") == "terminal" then
          vim.api.nvim_win_call(claude_term_neovim_win_id, function()
            vim.cmd("startinsert")
          end)
        end
      end
    end
  -- No terminal exists
  else
    logger.debug("terminal", "No valid terminal exists, creating new one")
    M.open(cmd_string, env_table, config)
  end
end

--- @return number|nil
function M.get_active_bufnr()
  if terminal and terminal:buf_valid() and terminal.buf then
    if vim.api.nvim_buf_is_valid(terminal.buf) then
      return terminal.buf
    end
  end
  return nil
end

--- @return boolean
function M.is_available()
  return is_available()
end

-- For testing purposes
--- @return table|nil
function M._get_terminal_for_test()
  return terminal
end

return M

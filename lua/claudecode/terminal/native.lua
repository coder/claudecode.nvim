--- Native Neovim terminal provider for Claude Code.
-- @module claudecode.terminal.native

--- @type TerminalProvider
local M = {}

local bufnr = nil
local winid = nil
local jobid = nil
local tip_shown = false
local config = {}

local function cleanup_state()
  bufnr = nil
  winid = nil
  jobid = nil
end

local function is_valid()
  -- First check if we have a valid buffer
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    cleanup_state()
    return false
  end

  -- If buffer is valid but window is invalid, try to find a window displaying this buffer
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    -- Search all windows for our terminal buffer
    local windows = vim.api.nvim_list_wins()
    for _, win in ipairs(windows) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        -- Found a window displaying our terminal buffer, update the tracked window ID
        winid = win
        require("claudecode.logger").debug("terminal", "Recovered terminal window ID:", win)
        return true
      end
    end
    -- Buffer exists but no window displays it
    cleanup_state()
    return false
  end

  -- Both buffer and window are valid
  return true
end

local function open_terminal(cmd_string, env_table, effective_config)
  if is_valid() then -- Should not happen if called correctly, but as a safeguard
    vim.api.nvim_set_current_win(winid)
    vim.cmd("startinsert")
    return true
  end

  local original_win = vim.api.nvim_get_current_win()
  local width = math.floor(vim.o.columns * effective_config.split_width_percentage)
  local full_height = vim.o.lines
  local placement_modifier

  if effective_config.split_side == "left" then
    placement_modifier = "topleft "
  else
    placement_modifier = "botright "
  end

  vim.cmd(placement_modifier .. width .. "vsplit")
  local new_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(new_winid, full_height)

  vim.api.nvim_win_call(new_winid, function()
    vim.cmd("enew")
  end)

  local term_cmd_arg
  if cmd_string:find(" ", 1, true) then
    term_cmd_arg = vim.split(cmd_string, " ", { plain = true, trimempty = false })
  else
    term_cmd_arg = { cmd_string }
  end

  jobid = vim.fn.termopen(term_cmd_arg, {
    env = env_table,
    on_exit = function(job_id, _, _)
      vim.schedule(function()
        if job_id == jobid then
          -- Ensure we are operating on the correct window and buffer before closing
          local current_winid_for_job = winid
          local current_bufnr_for_job = bufnr

          cleanup_state() -- Clear our managed state first

          if current_winid_for_job and vim.api.nvim_win_is_valid(current_winid_for_job) then
            if current_bufnr_for_job and vim.api.nvim_buf_is_valid(current_bufnr_for_job) then
              -- Optional: Check if the window still holds the same terminal buffer
              if vim.api.nvim_win_get_buf(current_winid_for_job) == current_bufnr_for_job then
                vim.api.nvim_win_close(current_winid_for_job, true)
              end
            else
              -- Buffer is invalid, but window might still be there (e.g. if user changed buffer in term window)
              -- Still try to close the window we tracked.
              vim.api.nvim_win_close(current_winid_for_job, true)
            end
          end
        end
      end)
    end,
  })

  if not jobid or jobid == 0 then
    vim.notify("Failed to open native terminal.", vim.log.levels.ERROR)
    vim.api.nvim_win_close(new_winid, true)
    vim.api.nvim_set_current_win(original_win)
    cleanup_state()
    return false
  end

  winid = new_winid
  bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].bufhidden = "wipe" -- Wipe buffer when hidden (e.g., window closed)
  -- buftype=terminal is set by termopen

  vim.api.nvim_set_current_win(winid)
  vim.cmd("startinsert")

  if config.show_native_term_exit_tip and not tip_shown then
    vim.notify("Native terminal opened. Press Ctrl-\\ Ctrl-N to return to Normal mode.", vim.log.levels.INFO)
    tip_shown = true
  end
  return true
end

local function close_terminal()
  if is_valid() then
    -- Closing the window should trigger on_exit of the job if the process is still running,
    -- which then calls cleanup_state.
    -- If the job already exited, on_exit would have cleaned up.
    -- This direct close is for user-initiated close.
    vim.api.nvim_win_close(winid, true)
    cleanup_state() -- Ensure cleanup if on_exit doesn't fire (e.g. job already dead)
  end
end

local function focus_terminal()
  if is_valid() then
    vim.api.nvim_set_current_win(winid)
    vim.cmd("startinsert")
  end
end

local function find_existing_claude_terminal()
  local buffers = vim.api.nvim_list_bufs()
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
      -- Check if this is a Claude Code terminal by examining the buffer name or terminal job
      local buf_name = vim.api.nvim_buf_get_name(buf)
      -- Terminal buffers often have names like "term://..." that include the command
      if buf_name:match("claude") then
        -- Additional check: see if there's a window displaying this buffer
        local windows = vim.api.nvim_list_wins()
        for _, win in ipairs(windows) do
          if vim.api.nvim_win_get_buf(win) == buf then
            require("claudecode.logger").debug(
              "terminal",
              "Found existing Claude terminal in buffer",
              buf,
              "window",
              win
            )
            return buf, win
          end
        end
      end
    end
  end
  return nil, nil
end

--- @param term_config table
function M.setup(term_config)
  config = term_config or {}
end

--- @param cmd_string string
--- @param env_table table
--- @param effective_config table
function M.open(cmd_string, env_table, effective_config)
  if is_valid() then
    focus_terminal()
  else
    -- Check if there's an existing Claude terminal we lost track of
    local existing_buf, existing_win = find_existing_claude_terminal()
    if existing_buf and existing_win then
      -- Recover the existing terminal
      bufnr = existing_buf
      winid = existing_win
      -- Note: We can't recover the job ID easily, but it's less critical
      require("claudecode.logger").debug("terminal", "Recovered existing Claude terminal")
      focus_terminal()
    else
      if not open_terminal(cmd_string, env_table, effective_config) then
        vim.notify("Failed to open Claude terminal using native fallback.", vim.log.levels.ERROR)
      end
    end
  end
end

function M.close()
  close_terminal()
end

--- @param cmd_string string
--- @param env_table table
--- @param effective_config table
function M.toggle(cmd_string, env_table, effective_config)
  if is_valid() then
    local claude_term_neovim_win_id = winid
    local current_neovim_win_id = vim.api.nvim_get_current_win()

    if claude_term_neovim_win_id == current_neovim_win_id then
      close_terminal()
    else
      focus_terminal() -- This already calls startinsert
    end
  else
    -- Check if there's an existing Claude terminal we lost track of
    local existing_buf, existing_win = find_existing_claude_terminal()
    if existing_buf and existing_win then
      -- Recover the existing terminal
      bufnr = existing_buf
      winid = existing_win
      require("claudecode.logger").debug("terminal", "Recovered existing Claude terminal in toggle")

      -- Check if we're currently in this terminal
      local current_neovim_win_id = vim.api.nvim_get_current_win()
      if existing_win == current_neovim_win_id then
        close_terminal()
      else
        focus_terminal()
      end
    else
      if not open_terminal(cmd_string, env_table, effective_config) then
        vim.notify("Failed to open Claude terminal using native fallback (toggle).", vim.log.levels.ERROR)
      end
    end
  end
end

--- @return number|nil
function M.get_active_bufnr()
  if is_valid() then
    return bufnr
  end
  return nil
end

--- @return boolean
function M.is_available()
  return true -- Native provider is always available
end

return M

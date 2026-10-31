---Native Neovim terminal provider for Claude Code.
---@module 'claudecode.terminal.native'

local M = {}

local logger = require("claudecode.logger")
local utils = require("claudecode.utils")

local bufnr = nil
local winid = nil
local jobid = nil
local tip_shown = false

-- Set on each terminal buffer this provider starts. Unlike the state above, a buffer variable survives a reload
-- of this module, so the next module instance can adopt the terminal.
local OWNED_MARK = "claudecode_native_terminal"

---@type ClaudeCodeTerminalConfig
local config = require("claudecode.terminal").defaults

local function cleanup_state()
  bufnr = nil
  winid = nil
  jobid = nil
end

-- nvim_win_close raises E444 for the only window of the only tab page. Floating windows do not count.
local function is_last_window(win)
  if #vim.api.nvim_list_tabpages() > 1 then
    return false
  end
  for _, other in ipairs(vim.api.nvim_list_wins()) do
    if other ~= win and vim.api.nvim_win_get_config(other).relative == "" then
      return false
    end
  end
  return true
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
        logger.debug("terminal", "Recovered terminal window ID:", win)
        return true
      end
    end
    -- Buffer exists but no window displays it - this is normal for hidden terminals
    return true -- Buffer is valid even though not visible
  end

  -- Both buffer and window are valid
  return true
end

---Forgets the tracked terminal when its job exits. With auto_close, also closes the tracked window.
---@param job_id number
---@param auto_close boolean|nil
local function forget_exited_job(job_id, auto_close)
  if job_id ~= jobid then
    return
  end
  logger.debug("terminal", "Terminal process exited, cleaning up")

  -- Ensure we are operating on the correct window and buffer before closing
  local current_winid_for_job = winid
  local current_bufnr_for_job = bufnr

  cleanup_state() -- Clear our managed state first

  if not auto_close then
    return
  end

  if
    current_winid_for_job
    and vim.api.nvim_win_is_valid(current_winid_for_job)
    and not is_last_window(current_winid_for_job)
  then
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

local function open_terminal(cmd_string, env_table, effective_config, focus)
  focus = utils.normalize_focus(focus)

  if is_valid() then -- Should not happen if called correctly, but as a safeguard
    if focus then
      -- Focus existing terminal: switch to terminal window and enter insert mode
      vim.api.nvim_set_current_win(winid)
      if effective_config.auto_insert ~= false then
        vim.cmd("startinsert")
      end
    end
    -- If focus=false, preserve user context by staying in current window
    return
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

  -- Another plugin's autocmd can swap a different buffer into the split, so the code below uses this number.
  local new_bufnr = vim.api.nvim_create_buf(true, false)
  -- Marked before termopen, so an open() from a TermOpen autocmd adopts this terminal instead of starting another.
  vim.b[new_bufnr][OWNED_MARK] = true
  vim.api.nvim_win_set_buf(new_winid, new_bufnr)

  -- Shell-aware split + leading-tilde expansion so quoted args and "~/..."
  -- paths survive, while no shell touches bracketed model aliases like
  -- "opus[1m]" (see utils.parse_command).
  local term_cmd_arg = utils.parse_command(cmd_string)

  local termopen_opts = {
    env = env_table,
    cwd = effective_config.cwd,
    on_exit = function(job_id, _, _)
      vim.schedule(function()
        -- The session is over. With auto_close = false the buffer stays visible, and an open() must not adopt it.
        if vim.api.nvim_buf_is_valid(new_bufnr) then
          vim.b[new_bufnr][OWNED_MARK] = nil
        end
        forget_exited_job(job_id, effective_config.auto_close)
      end)
    end,
  }
  -- pcall runs inside the callback because nvim_buf_call rewraps a raised error with a stack traceback.
  local started, termopen_result = false, "Its buffer was deleted before termopen ran."
  if vim.api.nvim_buf_is_valid(new_bufnr) then
    vim.api.nvim_buf_call(new_bufnr, function()
      started, termopen_result = pcall(vim.fn.termopen, term_cmd_arg, termopen_opts)
    end)
  end

  -- termopen raises for a command that is not executable, and returns 0 or -1 instead when errors are silenced.
  local failure = nil
  if not started then
    failure = " " .. tostring(termopen_result)
  elseif termopen_result <= 0 then
    failure = ""
  elseif not vim.api.nvim_buf_is_valid(new_bufnr) then
    -- A TermOpen autocmd wiped the buffer. The wipe also stopped the job.
    failure = " Its buffer was deleted after termopen started."
  end

  if failure then
    vim.notify("Failed to open native terminal." .. failure, vim.log.levels.ERROR)
    -- Wiping the buffer closes the split, unless an autocmd swapped another buffer into it first.
    if vim.api.nvim_win_is_valid(new_winid) then
      vim.api.nvim_win_close(new_winid, true)
    end
    vim.api.nvim_set_current_win(original_win)
    if vim.api.nvim_buf_is_valid(new_bufnr) then
      vim.api.nvim_buf_delete(new_bufnr, { force = true })
    end
    cleanup_state()
    return
  end

  jobid = termopen_result
  if vim.api.nvim_win_get_buf(new_winid) ~= new_bufnr then
    vim.api.nvim_win_set_buf(new_winid, new_bufnr)
  end
  winid = new_winid
  bufnr = new_bufnr
  vim.bo[bufnr].bufhidden = "hide"
  -- buftype=terminal is set by termopen

  if focus then
    -- Focus the terminal: switch to terminal window and enter insert mode
    vim.api.nvim_set_current_win(winid)
    if effective_config.auto_insert ~= false then
      vim.cmd("startinsert")
    end
  else
    -- Preserve user context: return to the window they were in before terminal creation
    vim.api.nvim_set_current_win(original_win)
  end

  if config.show_native_term_exit_tip and not tip_shown then
    vim.notify("Native terminal opened. Press Ctrl-\\ Ctrl-N to return to Normal mode.", vim.log.levels.INFO)
    tip_shown = true
  end
end

local function close_terminal()
  if not is_valid() then
    return
  end
  local closing_bufnr, closing_jobid = bufnr, jobid
  cleanup_state()
  -- The wait below runs scheduled callbacks. An open() among them must start a new terminal, not adopt this one.
  vim.b[closing_bufnr][OWNED_MARK] = nil

  -- bufhidden=hide keeps the job running when only the window closes, so stop the job and delete the buffer.
  -- That closes its windows except the last one. Deleting a terminal buffer while a write to its job is pending hangs
  -- Neovim (neovim/neovim#42508). The wait runs the event loop, which ends those writes. For a job that
  -- ignores SIGHUP, the buffer is deleted after the timeout and Neovim kills the job later.
  local exited = false
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = closing_bufnr,
    once = true,
    callback = function()
      exited = true
    end,
  })
  -- jobstop returns 0 for a job that already exited, for example when close runs from a TermClose autocmd.
  -- TermClose has fired then, so waiting for it would block for the full timeout.
  if vim.fn.jobstop(closing_jobid) == 1 then
    -- A user's TermClose autocmd can delete the buffer first, and that also removes this buffer-local autocmd.
    vim.wait(1000, function()
      return exited or not vim.api.nvim_buf_is_valid(closing_bufnr)
    end, 10)
  end
  if vim.api.nvim_buf_is_valid(closing_bufnr) then
    vim.api.nvim_buf_delete(closing_bufnr, { force = true })
  end
end

local function focus_terminal()
  if is_valid() then
    vim.api.nvim_set_current_win(winid)
    if config.auto_insert ~= false then
      vim.cmd("startinsert")
    end
  end
end

local function is_terminal_visible()
  -- Check if our terminal buffer exists and is displayed in any window
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local windows = vim.api.nvim_list_wins()
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      -- Update our tracked window ID if we find the buffer in a different window
      winid = win
      return true
    end
  end

  -- Buffer exists but no window displays it
  winid = nil
  return false
end

local function hide_terminal()
  -- Hide the terminal window but keep the buffer and job alive
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and winid and vim.api.nvim_win_is_valid(winid) then
    -- Close the window - this preserves the buffer and job
    vim.api.nvim_win_close(winid, false)
    winid = nil -- Clear window reference

    logger.debug("terminal", "Terminal window hidden, process preserved")
  end
end

local function show_hidden_terminal(effective_config, focus)
  -- Show an existing hidden terminal buffer in a new window
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  -- Check if it's already visible
  if is_terminal_visible() then
    if focus then
      focus_terminal()
    end
    return true
  end

  local original_win = vim.api.nvim_get_current_win()

  -- Create a new window for the existing buffer
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

  -- Set the existing buffer in the new window
  vim.api.nvim_win_set_buf(new_winid, bufnr)
  winid = new_winid

  if focus then
    -- Focus the terminal: switch to terminal window and enter insert mode
    vim.api.nvim_set_current_win(winid)
    if effective_config.auto_insert ~= false then
      vim.cmd("startinsert")
    end
  else
    -- Preserve user context: return to the window they were in before showing terminal
    vim.api.nvim_set_current_win(original_win)
  end

  logger.debug("terminal", "Showed hidden terminal in new window")
  return true
end

---Tracks a visible terminal that this provider started but lost track of, for example after a module reload.
---@return boolean adopted
local function adopt_existing_terminal()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf][OWNED_MARK] then
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
          bufnr, winid, jobid = buf, win, vim.bo[buf].channel
          local adopted_jobid = jobid
          -- The job's on_exit runs in the module copy that started it, for example the one before a reload.
          vim.api.nvim_create_autocmd("TermClose", {
            buffer = buf,
            once = true,
            callback = function()
              vim.schedule(function()
                forget_exited_job(adopted_jobid, config.auto_close)
              end)
            end,
          })
          logger.debug("terminal", "Recovered existing Claude terminal in buffer", buf, "window", win)
          return true
        end
      end
    end
  end
  return false
end

---Setup the terminal module
---@param term_config ClaudeCodeTerminalConfig
function M.setup(term_config)
  config = term_config
end

--- @param cmd_string string
--- @param env_table table
--- @param effective_config table
--- @param focus boolean|nil
function M.open(cmd_string, env_table, effective_config, focus)
  focus = utils.normalize_focus(focus)

  if is_valid() then
    -- Check if terminal exists but is hidden (no window)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
      -- Terminal is hidden, show it by calling show_hidden_terminal
      show_hidden_terminal(effective_config, focus)
    else
      -- Terminal is already visible
      if focus then
        focus_terminal()
      end
    end
  else
    if adopt_existing_terminal() then
      if focus then
        focus_terminal() -- Focus recovered terminal
      end
      -- If focus=false, preserve user context by staying in current window
    else
      open_terminal(cmd_string, env_table, effective_config, focus)
    end
  end
end

function M.close()
  close_terminal()
end

---Simple toggle: always show/hide terminal regardless of focus
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
function M.simple_toggle(cmd_string, env_table, effective_config)
  -- Check if we have a valid terminal buffer (process running)
  local has_buffer = bufnr and vim.api.nvim_buf_is_valid(bufnr)
  local is_visible = has_buffer and is_terminal_visible()

  if is_visible then
    -- Terminal is visible, hide it (but keep process running)
    hide_terminal()
  else
    -- Terminal is not visible
    if has_buffer then
      -- Terminal process exists but is hidden, show it
      if show_hidden_terminal(effective_config, true) then
        logger.debug("terminal", "Showing hidden terminal")
      else
        logger.error("terminal", "Failed to show hidden terminal")
      end
    else
      -- No terminal process exists, check if there's an existing one we lost track of
      if adopt_existing_terminal() then
        focus_terminal()
      else
        -- No existing terminal found, create a new one
        open_terminal(cmd_string, env_table, effective_config)
      end
    end
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
function M.focus_toggle(cmd_string, env_table, effective_config)
  -- Check if we have a valid terminal buffer (process running)
  local has_buffer = bufnr and vim.api.nvim_buf_is_valid(bufnr)
  local is_visible = has_buffer and is_terminal_visible()

  if has_buffer then
    -- Terminal process exists
    if is_visible then
      -- Terminal is visible - check if we're currently in it
      local current_win_id = vim.api.nvim_get_current_win()
      if winid == current_win_id then
        -- We're in the terminal window, hide it (but keep process running)
        hide_terminal()
      else
        -- Terminal is visible but we're not in it, focus it
        focus_terminal()
      end
    else
      -- Terminal process exists but is hidden, show it
      if show_hidden_terminal(effective_config, true) then
        logger.debug("terminal", "Showing hidden terminal")
      else
        logger.error("terminal", "Failed to show hidden terminal")
      end
    end
  else
    -- No terminal process exists, check if there's an existing one we lost track of
    if adopt_existing_terminal() then
      -- Check if we're currently in this recovered terminal
      local current_win_id = vim.api.nvim_get_current_win()
      if winid == current_win_id then
        -- We're in the recovered terminal, hide it
        hide_terminal()
      else
        -- Focus the recovered terminal
        focus_terminal()
      end
    else
      -- No existing terminal found, create a new one
      open_terminal(cmd_string, env_table, effective_config)
    end
  end
end

--- Legacy toggle function for backward compatibility (defaults to simple_toggle)
--- @param cmd_string string
--- @param env_table table
--- @param effective_config ClaudeCodeTerminalConfig
function M.toggle(cmd_string, env_table, effective_config)
  M.simple_toggle(cmd_string, env_table, effective_config)
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

--- @type ClaudeCodeTerminalProvider
return M

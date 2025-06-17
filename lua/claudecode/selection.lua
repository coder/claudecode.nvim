---
-- Manages selection tracking and communication with the Claude server.
-- @module claudecode.selection
local M = {}

local logger = require("claudecode.logger")
local terminal = require("claudecode.terminal")

M.state = {
  latest_selection = nil,
  tracking_enabled = false,
  debounce_timer = nil,
  debounce_ms = 100,

  last_active_visual_selection = nil,
  demotion_timer = nil,
  visual_demotion_delay_ms = 50,
}

--- Enables selection tracking.
-- @param server table The server object to use for communication.
-- @param visual_demotion_delay_ms number The delay for visual selection demotion.
function M.enable(server, visual_demotion_delay_ms)
  if M.state.tracking_enabled then
    return
  end

  M.state.tracking_enabled = true
  M.server = server
  M.state.visual_demotion_delay_ms = visual_demotion_delay_ms

  M._create_autocommands()
end

--- Disables selection tracking.
-- Clears autocommands, resets internal state, and stops any active debounce timers.
function M.disable()
  if not M.state.tracking_enabled then
    return
  end

  M.state.tracking_enabled = false

  M._clear_autocommands()

  M.state.latest_selection = nil
  M.server = nil

  if M.state.debounce_timer then
    vim.loop.timer_stop(M.state.debounce_timer)
    M.state.debounce_timer = nil
  end
end

--- Creates autocommands for tracking selections.
-- Sets up listeners for CursorMoved, CursorMovedI, ModeChanged, and TextChanged events.
-- @local
function M._create_autocommands()
  local group = vim.api.nvim_create_augroup("ClaudeCodeSelection", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function()
      M.on_cursor_moved()
    end,
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function()
      M.on_mode_changed()
    end,
  })

  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    callback = function()
      M.on_text_changed()
    end,
  })
end

--- Clears the autocommands related to selection tracking.
-- @local
function M._clear_autocommands()
  vim.api.nvim_clear_autocmds({ group = "ClaudeCodeSelection" })
end

--- Handles cursor movement events.
-- Triggers a debounced update of the selection.
function M.on_cursor_moved()
  M.debounce_update()
end

--- Handles mode change events.
-- Triggers an immediate update of the selection.
function M.on_mode_changed()
  M.update_selection()
end

--- Handles text change events.
-- Triggers a debounced update of the selection.
function M.on_text_changed()
  M.debounce_update()
end

--- Debounces selection updates.
-- Ensures that `update_selection` is not called too frequently by deferring
-- its execution.
function M.debounce_update()
  if M.state.debounce_timer then
    vim.loop.timer_stop(M.state.debounce_timer)
  end

  M.state.debounce_timer = vim.defer_fn(function()
    M.update_selection()
    M.state.debounce_timer = nil
  end, M.state.debounce_ms)
end

--- Updates the current selection state.
-- Determines the current selection based on the editor mode (visual or normal)
-- and sends an update to the server if the selection has changed.
function M.update_selection()
  if not M.state.tracking_enabled then
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local buf_name = vim.api.nvim_buf_get_name(current_buf)

  -- If the buffer name starts with "✻ [Claude Code]", do not update selection
  if buf_name and string.sub(buf_name, 1, string.len("✻ [Claude Code]")) == "✻ [Claude Code]" then
    -- Optionally, cancel demotion timer like for the terminal
    if M.state.demotion_timer then
      M.state.demotion_timer:stop()
      M.state.demotion_timer:close()
      M.state.demotion_timer = nil
    end
    return
  end

  -- If the current buffer is the Claude terminal, do not update selection
  if terminal then
    local claude_term_bufnr = terminal.get_active_terminal_bufnr()
    if claude_term_bufnr and current_buf == claude_term_bufnr then
      -- Cancel any pending demotion if we switch to the Claude terminal
      if M.state.demotion_timer then
        M.state.demotion_timer:stop()
        M.state.demotion_timer:close()
        M.state.demotion_timer = nil
      end
      return
    end
  end

  local current_mode_info = vim.api.nvim_get_mode()
  local current_mode = current_mode_info.mode
  local current_selection

  if current_mode == "v" or current_mode == "V" or current_mode == "\022" then
    -- If a new visual selection is made, cancel any pending demotion
    if M.state.demotion_timer then
      M.state.demotion_timer:stop()
      M.state.demotion_timer:close()
      M.state.demotion_timer = nil
    end

    current_selection = M.get_visual_selection()

    if current_selection then
      M.state.last_active_visual_selection = {
        bufnr = current_buf,
        selection_data = vim.deepcopy(current_selection), -- Store a copy
        timestamp = vim.loop.now(),
      }
    else
      -- No valid visual selection (e.g., get_visual_selection returned nil)
      -- Clear last_active_visual if it was for this buffer
      if M.state.last_active_visual_selection and M.state.last_active_visual_selection.bufnr == current_buf then
        M.state.last_active_visual_selection = nil
      end
    end
  else
    local last_visual = M.state.last_active_visual_selection

    if M.state.demotion_timer then
      -- A demotion is already pending. For this specific update_selection call (e.g. cursor moved),
      -- current_selection reflects the immediate cursor position.
      -- M.state.latest_selection (the one that might be sent) is still the visual one until timer resolves.
      current_selection = M.get_cursor_position()
    elseif
      last_visual
      and last_visual.bufnr == current_buf
      and last_visual.selection_data
      and not last_visual.selection_data.selection.isEmpty
    then
      -- We just exited visual mode in this buffer, and no demotion timer is running for it.
      -- Keep M.state.latest_selection as is (it's the visual one from the previous update).
      -- The 'current_selection' for comparison should also be this visual one.
      current_selection = M.state.latest_selection

      if M.state.demotion_timer then -- Should not happen due to elseif, but as safeguard
        M.state.demotion_timer:stop()
        M.state.demotion_timer:close()
      end

      M.state.demotion_timer = vim.loop.new_timer()
      M.state.demotion_timer:start(
        M.state.visual_demotion_delay_ms,
        0, -- 0 repeat = one-shot
        vim.schedule_wrap(function()
          if M.state.demotion_timer then -- Check if it wasn't cancelled right before firing
            M.state.demotion_timer:stop()
            M.state.demotion_timer:close()
            M.state.demotion_timer = nil
          end
          M.handle_selection_demotion(current_buf) -- Pass buffer at time of scheduling
        end)
      )
    else
      -- Genuinely in normal mode, no recent visual exit, no pending demotion.
      current_selection = M.get_cursor_position()
      if last_visual and last_visual.bufnr == current_buf then
        M.state.last_active_visual_selection = nil -- Clear it as it's no longer relevant for demotion
      end
    end
  end

  -- If current_selection could not be determined (e.g. get_visual_selection was nil and no other path set it)
  -- default to cursor position to avoid errors.
  if not current_selection then
    current_selection = M.get_cursor_position()
  end

  local changed = M.has_selection_changed(current_selection)

  if changed then
    M.state.latest_selection = current_selection
    if M.server then
      M.send_selection_update(current_selection)
    end
  end
end

--- Handles the demotion of a visual selection after a delay.
-- Called by the demotion_timer.
-- @param original_bufnr_when_scheduled number The buffer number that was active when demotion was scheduled.
function M.handle_selection_demotion(original_bufnr_when_scheduled)
  -- Timer object is already stopped and cleared by its own callback wrapper or cancellation points.
  -- M.state.demotion_timer should be nil here if it fired normally or was cancelled.

  local current_buf = vim.api.nvim_get_current_buf()
  local claude_term_bufnr = terminal.get_active_terminal_bufnr()

  -- Condition 1: Switched to Claude Terminal
  if claude_term_bufnr and current_buf == claude_term_bufnr then
    -- Visual selection is preserved (M.state.latest_selection is still the visual one).
    -- The "pending" status of last_active_visual_selection is resolved.
    if
      M.state.last_active_visual_selection
      and M.state.last_active_visual_selection.bufnr == original_bufnr_when_scheduled
    then
      M.state.last_active_visual_selection = nil
    end
    return
  end

  local current_mode_info = vim.api.nvim_get_mode()

  -- Condition 2: Back in Visual Mode in the Original Buffer
  if
    current_buf == original_bufnr_when_scheduled
    and (current_mode_info.mode == "v" or current_mode_info.mode == "V" or current_mode_info.mode == "\022")
  then
    -- A new visual selection will take precedence. M.state.latest_selection will be updated by main flow.
    if
      M.state.last_active_visual_selection
      and M.state.last_active_visual_selection.bufnr == original_bufnr_when_scheduled
    then
      M.state.last_active_visual_selection = nil
    end
    return
  end

  -- Condition 3: Still in Original Buffer & Not Visual & Not Claude Term -> Demote
  if current_buf == original_bufnr_when_scheduled then
    local new_sel_for_demotion = M.get_cursor_position()
    -- Check if this new cursor position is actually different from the (visual) latest_selection
    if M.has_selection_changed(new_sel_for_demotion) then
      M.state.latest_selection = new_sel_for_demotion
      if M.server then
        M.send_selection_update(M.state.latest_selection)
      end
    end
    -- No change detected in selection
  end
  -- User switched to different buffer

  -- Always clear last_active_visual_selection for the original buffer as its pending demotion is resolved.
  if
    M.state.last_active_visual_selection
    and M.state.last_active_visual_selection.bufnr == original_bufnr_when_scheduled
  then
    M.state.last_active_visual_selection = nil
  end
end

--- Validates if we're in a valid visual selection mode
-- @return boolean, string|nil - true if valid, false and error message if not
local function validate_visual_mode()
  local current_nvim_mode = vim.api.nvim_get_mode().mode
  local fixed_anchor_pos_raw = vim.fn.getpos("v")

  if not (current_nvim_mode == "v" or current_nvim_mode == "V" or current_nvim_mode == "\22") then
    return false, "not in visual mode"
  end

  if fixed_anchor_pos_raw[2] == 0 then
    return false, "no visual selection mark"
  end

  return true, nil
end

--- Determines the effective visual mode character
-- @return string|nil - the visual mode character or nil if invalid
local function get_effective_visual_mode()
  local current_nvim_mode = vim.api.nvim_get_mode().mode
  local visual_fn_mode_char = vim.fn.visualmode()

  if visual_fn_mode_char and visual_fn_mode_char ~= "" then
    return visual_fn_mode_char
  end

  -- Fallback to current mode
  if current_nvim_mode == "V" then
    return "V"
  elseif current_nvim_mode == "v" then
    return "v"
  elseif current_nvim_mode == "\22" then -- Ctrl-V, blockwise
    return "\22"
  end

  return nil
end

--- Gets the start and end coordinates of the visual selection
-- @return table, table - start_coords and end_coords with lnum and col fields
local function get_selection_coordinates()
  local fixed_anchor_pos_raw = vim.fn.getpos("v")
  local current_cursor_nvim = vim.api.nvim_win_get_cursor(0)

  -- Convert to 1-indexed line and 1-indexed column for consistency
  local p1 = { lnum = fixed_anchor_pos_raw[2], col = fixed_anchor_pos_raw[3] }
  local p2 = { lnum = current_cursor_nvim[1], col = current_cursor_nvim[2] + 1 }

  -- Determine chronological start/end based on line, then column
  if p1.lnum < p2.lnum or (p1.lnum == p2.lnum and p1.col <= p2.col) then
    return p1, p2
  else
    return p2, p1
  end
end

--- Extracts text for linewise visual selection
-- @param lines_content table - array of line strings
-- @param start_coords table - start coordinates
-- @return string - the extracted text
local function extract_linewise_text(lines_content, start_coords)
  start_coords.col = 1 -- Linewise selection effectively starts at column 1
  return table.concat(lines_content, "\n")
end

--- Extracts text for characterwise visual selection
-- @param lines_content table - array of line strings
-- @param start_coords table - start coordinates
-- @param end_coords table - end coordinates
-- @return string|nil - the extracted text or nil if invalid
local function extract_characterwise_text(lines_content, start_coords, end_coords)
  if start_coords.lnum == end_coords.lnum then
    if not lines_content[1] then
      return nil
    end
    return string.sub(lines_content[1], start_coords.col, end_coords.col)
  else
    if not lines_content[1] or not lines_content[#lines_content] then
      return nil
    end

    local text_parts = {}
    table.insert(text_parts, string.sub(lines_content[1], start_coords.col))
    for i = 2, #lines_content - 1 do
      table.insert(text_parts, lines_content[i])
    end
    table.insert(text_parts, string.sub(lines_content[#lines_content], 1, end_coords.col))
    return table.concat(text_parts, "\n")
  end
end

--- Calculates LSP-compatible position coordinates
-- @param start_coords table - start coordinates
-- @param end_coords table - end coordinates
-- @param visual_mode string - the visual mode character
-- @param lines_content table - array of line strings
-- @return table - LSP position object with start and end fields
local function calculate_lsp_positions(start_coords, end_coords, visual_mode, lines_content)
  local lsp_start_line = start_coords.lnum - 1
  local lsp_end_line = end_coords.lnum - 1
  local lsp_start_char, lsp_end_char

  if visual_mode == "V" then
    lsp_start_char = 0 -- Linewise selection always starts at character 0
    -- For linewise, LSP end char is length of the last selected line
    if #lines_content > 0 and lines_content[#lines_content] then
      lsp_end_char = #lines_content[#lines_content]
    else
      lsp_end_char = 0
    end
  else
    lsp_start_char = start_coords.col - 1
    lsp_end_char = end_coords.col
  end

  return {
    start = { line = lsp_start_line, character = lsp_start_char },
    ["end"] = { line = lsp_end_line, character = lsp_end_char },
  }
end

--- Gets the current visual selection details.
-- @return table|nil A table containing selection text, file path, URL, and
--                   start/end positions, or nil if no visual selection exists.
function M.get_visual_selection()
  local valid = validate_visual_mode()
  if not valid then
    return nil
  end

  local visual_mode = get_effective_visual_mode()
  if not visual_mode then
    return nil
  end

  local start_coords, end_coords = get_selection_coordinates()

  local current_buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(current_buf)

  local lines_content = vim.api.nvim_buf_get_lines(
    current_buf,
    start_coords.lnum - 1, -- Convert to 0-indexed
    end_coords.lnum, -- nvim_buf_get_lines end is exclusive
    false
  )

  if #lines_content == 0 then
    return nil
  end

  local final_text
  if visual_mode == "V" then
    final_text = extract_linewise_text(lines_content, start_coords)
  elseif visual_mode == "v" or visual_mode == "\22" then
    final_text = extract_characterwise_text(lines_content, start_coords, end_coords)
    if not final_text then
      return nil
    end
  else
    return nil
  end

  local lsp_positions = calculate_lsp_positions(start_coords, end_coords, visual_mode, lines_content)

  return {
    text = final_text or "",
    filePath = file_path,
    fileUrl = "file://" .. file_path,
    selection = {
      start = lsp_positions.start,
      ["end"] = lsp_positions["end"],
      isEmpty = (not final_text or #final_text == 0),
    },
  }
end

--- Gets the current cursor position when no visual selection is active.
-- @return table A table containing an empty text, file path, URL, and cursor
--               position as start/end, with isEmpty set to true.
function M.get_cursor_position()
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local current_buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(current_buf)

  return {
    text = "",
    filePath = file_path,
    fileUrl = "file://" .. file_path,
    selection = {
      start = { line = cursor_pos[1] - 1, character = cursor_pos[2] },
      ["end"] = { line = cursor_pos[1] - 1, character = cursor_pos[2] },
      isEmpty = true,
    },
  }
end

--- Checks if the selection has changed compared to the latest stored selection.
-- @param new_selection table|nil The new selection object to compare.
-- @return boolean true if the selection has changed, false otherwise.
function M.has_selection_changed(new_selection)
  local old_selection = M.state.latest_selection

  if not new_selection then
    return old_selection ~= nil
  end

  if not old_selection then
    return true
  end

  if old_selection.filePath ~= new_selection.filePath then
    return true
  end

  if old_selection.text ~= new_selection.text then
    return true
  end

  if
    old_selection.selection.start.line ~= new_selection.selection.start.line
    or old_selection.selection.start.character ~= new_selection.selection.start.character
    or old_selection.selection["end"].line ~= new_selection.selection["end"].line
    or old_selection.selection["end"].character ~= new_selection.selection["end"].character
  then
    return true
  end

  return false
end

--- Sends the selection update to the Claude server.
-- @param selection table The selection object to send.
function M.send_selection_update(selection)
  M.server.broadcast("selection_changed", selection)
end

--- Gets the latest recorded selection.
-- @return table|nil The latest selection object, or nil if none recorded.
function M.get_latest_selection()
  return M.state.latest_selection
end

--- Sends the current selection to Claude.
-- This function is typically invoked by a user command. It forces an immediate
-- update and sends the latest selection.
function M.send_current_selection()
  if not M.state.tracking_enabled or not M.server then
    logger.error("selection", "Claude Code is not running")
    return
  end

  M.update_selection()

  local selection = M.state.latest_selection

  if not selection then
    logger.error("selection", "No selection available")
    return
  end

  M.send_selection_update(selection)

  vim.api.nvim_echo({ { "Selection sent to Claude", "Normal" } }, false, {})
end

--- Gets selection from range marks (e.g., when using :'<,'> commands)
-- @param line1 number The start line (1-indexed)
-- @param line2 number The end line (1-indexed)
-- @return table|nil A table containing selection text, file path, URL, and
--                   start/end positions, or nil if invalid range
function M.get_range_selection(line1, line2)
  if not line1 or not line2 or line1 < 1 or line2 < 1 or line1 > line2 then
    return nil
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(current_buf)

  -- Get the total number of lines in the buffer
  local total_lines = vim.api.nvim_buf_line_count(current_buf)

  -- Ensure line2 doesn't exceed buffer bounds
  if line2 > total_lines then
    line2 = total_lines
  end

  local lines_content = vim.api.nvim_buf_get_lines(
    current_buf,
    line1 - 1, -- Convert to 0-indexed
    line2, -- nvim_buf_get_lines end is exclusive
    false
  )

  if #lines_content == 0 then
    return nil
  end

  local final_text = table.concat(lines_content, "\n")

  -- For range selections, we treat them as linewise
  local lsp_start_line = line1 - 1 -- Convert to 0-indexed
  local lsp_end_line = line2 - 1
  local lsp_start_char = 0
  local lsp_end_char = #lines_content[#lines_content]

  return {
    text = final_text or "",
    filePath = file_path,
    fileUrl = "file://" .. file_path,
    selection = {
      start = { line = lsp_start_line, character = lsp_start_char },
      ["end"] = { line = lsp_end_line, character = lsp_end_char },
      isEmpty = (not final_text or #final_text == 0),
    },
  }
end

--- Sends an at_mentioned notification for the current visual selection.
-- @param line1 number|nil Optional start line for range-based selection
-- @param line2 number|nil Optional end line for range-based selection
function M.send_at_mention_for_visual_selection(line1, line2)
  if not M.state.tracking_enabled then
    logger.error("selection", "Selection tracking is not enabled.")
    return false
  end

  -- Check if Claude Code integration is running (server may or may not have clients)
  local claudecode_main = require("claudecode")
  if not claudecode_main.state.server then
    logger.error("selection", "Claude Code integration is not running.")
    return false
  end

  local sel_to_send

  -- If range parameters are provided, use them (for :'<,'> commands)
  if line1 and line2 then
    sel_to_send = M.get_range_selection(line1, line2)
    if not sel_to_send or sel_to_send.selection.isEmpty then
      logger.warn("selection", "Invalid range selection to send as at-mention.")
      return false
    end
  else
    -- Use existing logic for visual mode or tracked selection
    sel_to_send = M.state.latest_selection

    if not sel_to_send or sel_to_send.selection.isEmpty then
      -- Fallback: try to get current visual selection directly.
      -- This helps if latest_selection was demoted or command was too fast.
      local current_visual = M.get_visual_selection()
      if current_visual and not current_visual.selection.isEmpty then
        sel_to_send = current_visual
      else
        logger.warn("selection", "No visual selection to send as at-mention.")
        return false
      end
    end
  end

  -- Sanity check: ensure the selection is for the current buffer
  local current_buf_name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  if sel_to_send.filePath ~= current_buf_name then
    logger.warn(
      "selection",
      "Tracked selection is for '"
        .. sel_to_send.filePath
        .. "', but current buffer is '"
        .. current_buf_name
        .. "'. Not sending."
    )
    return false
  end

  -- Use connection-aware broadcasting from main module
  local file_path = sel_to_send.filePath
  local start_line = sel_to_send.selection.start.line -- Already 0-indexed from selection module
  local end_line = sel_to_send.selection["end"].line -- Already 0-indexed

  local success, error_msg = claudecode_main.send_at_mention(file_path, start_line, end_line, "ClaudeCodeSend")

  if success then
    logger.debug("selection", "Visual selection sent as at-mention.")

    return true
  else
    logger.error("selection", "Failed to send at-mention: " .. (error_msg or "unknown error"))
    return false
  end
end
return M

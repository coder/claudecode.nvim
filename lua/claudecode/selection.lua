---Manages selection tracking and communication with the Claude server.
---@module 'claudecode.selection'
local M = {}

local logger = require("claudecode.logger")
local terminal = require("claudecode.terminal")

local uv = vim.uv or vim.loop

-- The selection type (v, V or CTRL-V) of each mode that has a selection. Select mode (s, S, CTRL-S) has the same
-- selection as Visual mode, and so does Visual mode for one command after CTRL-O in Select mode (vs, Vs, CTRL-Vs).
local SELECTION_TYPE = {
  v = "v",
  V = "V",
  ["\22"] = "\22",
  s = "v",
  S = "V",
  ["\19"] = "\22",
  vs = "v",
  Vs = "V",
  ["\22s"] = "\22",
}

---Returns true if the given mode string has a visual selection (Visual or Select mode).
---@param mode string|nil
---@return boolean
local function is_visual_mode(mode)
  return SELECTION_TYPE[mode] ~= nil
end

---Returns true if the cursor is still at the position captured by the most recent flush
---for this buffer (i.e. the held visual selection has not been navigated away from yet).
---@param bufnr number
---@return boolean
local function cursor_unmoved_since_flush(bufnr)
  local caf = M.state.cursor_at_flush
  if not caf or caf.bufnr ~= bufnr then
    return false
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  return pos[1] == caf.pos[1] and pos[2] == caf.pos[2]
end

M.state = {
  latest_selection = nil,
  tracking_enabled = false,
  debounce_timer = nil,
  debounce_ms = 100,

  last_active_visual_selection = nil,
  demotion_timer = nil,
  visual_demotion_delay_ms = 50,

  -- Cursor position captured when a visual selection is flushed on visual-mode exit.
  -- Demotion only fires once the cursor actually moves away from this position, so a
  -- held selection persists (see issue #246 and M.flush_visual_selection).
  cursor_at_flush = nil,

  -- { bufnr, tick } captured when visual mode is entered. Used to detect that an operator
  -- consumed/mutated the selection (d/c/>/x...) so the flush does not broadcast stale,
  -- post-edit marks as a phantom selection (see M.flush_visual_selection).
  visual_entry = nil,
}

---Enables selection tracking.
---@param server table The server object to use for communication.
---@param visual_demotion_delay_ms number The delay for visual selection demotion.
function M.enable(server, visual_demotion_delay_ms)
  if M.state.tracking_enabled then
    return
  end

  M.state.tracking_enabled = true
  M.server = server
  M.state.visual_demotion_delay_ms = visual_demotion_delay_ms

  M._create_autocommands()
end

---Disables selection tracking.
---Clears autocommands, resets internal state, and stops any active debounce or
---demotion timers.
function M.disable()
  if not M.state.tracking_enabled then
    return
  end

  M.state.tracking_enabled = false

  M._clear_autocommands()

  M.state.latest_selection = nil
  M.state.last_active_visual_selection = nil
  M.state.cursor_at_flush = nil
  M.state.visual_entry = nil
  M.server = nil

  M._cancel_debounce_timer()
  M._cancel_demotion_timer()
end

---Cancels and closes the current debounce timer, if any.
---@local
function M._cancel_debounce_timer()
  local timer = M.state.debounce_timer
  if not timer then
    return
  end

  -- Clear state before stopping/closing so any already-scheduled callback is a no-op.
  M.state.debounce_timer = nil

  timer:stop()
  timer:close()
end

---Cancels and closes the current demotion timer, if any.
---@local
function M._cancel_demotion_timer()
  local timer = M.state.demotion_timer
  if not timer then
    return
  end

  -- Clear state before stopping/closing so any already-scheduled callback is a no-op.
  M.state.demotion_timer = nil

  timer:stop()
  timer:close()
end

---Creates autocommands for tracking selections.
---Sets up listeners for CursorMoved, CursorMovedI, BufEnter, ModeChanged, and TextChanged events.
---@local
function M._create_autocommands()
  local group = vim.api.nvim_create_augroup("ClaudeCodeSelection", { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufEnter" }, {
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

---Clears the autocommands related to selection tracking.
---@local
function M._clear_autocommands()
  vim.api.nvim_clear_autocmds({ group = "ClaudeCodeSelection" })
end

---Handles cursor movement events.
---Triggers a debounced update of the selection.
function M.on_cursor_moved()
  M.debounce_update()
end

---Handles mode change events.
---When leaving visual mode, the selection is flushed synchronously: at that instant
---`nvim_get_mode()` already reports the new (non-visual) mode, so the debounced
---`update_selection()` path can no longer capture the visual selection. Flushing here
---(from the still-valid `'<`/`'>` marks) ensures fast selections that are made and
---released in under `debounce_ms` are not lost (issue #246).
---Entering visual mode records the buffer's changedtick so the flush can tell an
---abandoned selection apart from one consumed by a mutating operator (d/c/>/x...).
function M.on_mode_changed()
  local event = vim.v.event
  if event then
    local leaving_visual = is_visual_mode(event.old_mode) and not is_visual_mode(event.new_mode)
    local entering_visual = is_visual_mode(event.new_mode) and not is_visual_mode(event.old_mode)
    if entering_visual then
      local buf = vim.api.nvim_get_current_buf()
      M.state.visual_entry = { bufnr = buf, tick = vim.api.nvim_buf_get_changedtick(buf) }
    elseif leaving_visual then
      M.flush_visual_selection()
    end
  end

  M.debounce_update()
end

---Handles text change events.
---Triggers a debounced update of the selection.
function M.on_text_changed()
  M.debounce_update()
end

---Debounces selection updates.
---Ensures that `update_selection` is not called too frequently by deferring
---its execution.
function M.debounce_update()
  M._cancel_debounce_timer()

  assert(type(M.state.debounce_ms) == "number", "Expected debounce_ms to be a number")

  local timer = uv.new_timer()
  assert(timer, "Expected uv.new_timer() to return a timer handle")
  assert(timer.start, "Expected debounce timer to have :start()")
  assert(timer.stop, "Expected debounce timer to have :stop()")
  assert(timer.close, "Expected debounce timer to have :close()")

  M.state.debounce_timer = timer

  timer:start(
    M.state.debounce_ms,
    0, -- 0 repeat = one-shot
    vim.schedule_wrap(function()
      -- Ignore stale timers (e.g., cancelled and replaced before callback runs)
      if M.state.debounce_timer ~= timer then
        return
      end

      -- Clear state so _cancel_debounce_timer() is a no-op if called after firing.
      M.state.debounce_timer = nil

      timer:stop()
      timer:close()

      M.update_selection()
    end)
  )
end

---Updates the current selection state.
---Determines the current selection based on the editor mode (visual or normal)
---and sends an update to the server if the selection has changed.
function M.update_selection()
  if not M.state.tracking_enabled then
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local buf_name = vim.api.nvim_buf_get_name(current_buf)

  -- If the buffer name starts with "term://" and contains "claude", do not update selection
  if buf_name and buf_name:match("^term://") and buf_name:lower():find("claude", 1, true) then
    -- Optionally, cancel demotion timer like for the terminal
    M._cancel_demotion_timer()
    return
  end

  -- If the current buffer is the Claude terminal, do not update selection
  if terminal then
    local claude_term_bufnr = terminal.get_active_terminal_bufnr()
    if claude_term_bufnr and current_buf == claude_term_bufnr then
      -- Cancel any pending demotion if we switch to the Claude terminal
      M._cancel_demotion_timer()
      return
    end
  end

  local current_mode_info = vim.api.nvim_get_mode()
  local current_mode = current_mode_info.mode
  local current_selection

  if is_visual_mode(current_mode) then
    -- If a new visual selection is made, cancel any pending demotion
    M._cancel_demotion_timer()

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
      -- A demotion is already pending. While the cursor is still on the flushed position the
      -- held visual selection must be preserved (an idle re-entry here must not wipe it before
      -- the cursor actually moves -- matters when visual_demotion_delay_ms >= debounce_ms).
      -- Once the cursor has moved, reflect the immediate cursor position; M.state.latest_selection
      -- stays the visual one until the timer resolves.
      if cursor_unmoved_since_flush(current_buf) then
        current_selection = M.state.latest_selection
      else
        current_selection = M.get_cursor_position()
      end
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

      local timer = uv.new_timer()
      assert(timer, "Expected uv.new_timer() to return a timer handle")

      M.state.demotion_timer = timer
      timer:start(
        M.state.visual_demotion_delay_ms,
        0, -- 0 repeat = one-shot
        vim.schedule_wrap(function()
          -- Ignore stale timers (e.g., cancelled and replaced before callback runs)
          if M.state.demotion_timer ~= timer then
            return
          end

          -- Clear state so _cancel_demotion_timer() is a no-op if called after firing.
          M.state.demotion_timer = nil

          timer:stop()
          timer:close()

          M.handle_selection_demotion(current_buf) -- Pass buffer at time of scheduling
        end)
      )
    else
      -- Genuinely in normal mode, no recent visual exit, no pending demotion. The
      -- selection_changed protocol reflects the active editor, so report this buffer's
      -- cursor. Any held visual selection (for this buffer, or one navigated away from
      -- without moving the cursor) is no longer current -- clear its tracked state so it
      -- does not leak across buffer switches.
      current_selection = M.get_cursor_position()
      M.state.last_active_visual_selection = nil
      M.state.cursor_at_flush = nil
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

---Handles the demotion of a visual selection after a delay.
---Called by the demotion_timer.
---@param original_bufnr_when_scheduled number The buffer number that was active when demotion was scheduled.
function M.handle_selection_demotion(original_bufnr_when_scheduled)
  -- Timer object is already stopped and cleared by its own callback wrapper or cancellation points.
  -- M.state.demotion_timer should be nil here if it fired normally or was cancelled.

  if not M.state.tracking_enabled then
    return
  end

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
  if current_buf == original_bufnr_when_scheduled and is_visual_mode(current_mode_info.mode) then
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
    -- Only demote once the cursor has actually moved since the selection was flushed.
    -- This lets a held selection persist (matching the official VS Code extension, and
    -- fixing the external-Claude case where there is no in-Neovim Claude terminal to
    -- switch to), while still clearing a stale selection as soon as the user navigates
    -- away from it. last_active_visual_selection is intentionally left intact when the
    -- cursor is unmoved so a later cursor move re-arms demotion. See issue #246.
    if cursor_unmoved_since_flush(current_buf) then
      return
    end

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

  -- The pending demotion for the original buffer is resolved: clear its tracked state.
  if
    M.state.last_active_visual_selection
    and M.state.last_active_visual_selection.bufnr == original_bufnr_when_scheduled
  then
    M.state.last_active_visual_selection = nil
  end
  if M.state.cursor_at_flush and M.state.cursor_at_flush.bufnr == original_bufnr_when_scheduled then
    M.state.cursor_at_flush = nil
  end
end

---Validates if we're in a valid visual selection mode
---@return boolean valid, string? error - true if valid, false and error message if not
local function validate_visual_mode()
  local current_nvim_mode = vim.api.nvim_get_mode().mode
  local fixed_anchor_pos_raw = vim.fn.getpos("v")

  if not is_visual_mode(current_nvim_mode) then
    return false, "not in visual mode"
  end

  if fixed_anchor_pos_raw[2] == 0 then
    return false, "no visual selection mark"
  end

  return true, nil
end

---Determines the effective visual mode character.
---Prefers the LIVE mode; `vim.fn.visualmode()` (the LAST COMPLETED visual mode) is only
---used as a fallback when not currently in a visual mode. Trusting `visualmode()` while
---live in a different visual mode misclassifies the selection -- e.g. a fresh linewise
---`V` made right after a charwise selection would be extracted charwise, broadcasting a
---single character (or an empty selection on an empty line) instead of the whole line.
---See issue #246.
---@return string|nil - the visual mode character or nil if invalid
local function get_effective_visual_mode()
  local live_type = SELECTION_TYPE[vim.api.nvim_get_mode().mode]
  if live_type then
    return live_type
  end

  -- Not currently in a visual mode: fall back to the last completed visual mode.
  local visual_fn_mode_char = vim.fn.visualmode()
  if visual_fn_mode_char and visual_fn_mode_char ~= "" then
    return visual_fn_mode_char
  end

  return nil
end

---Gets the start and end coordinates of the visual selection
---@return table, table - start_coords and end_coords with lnum and col fields
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

---Returns the length of the well-formed UTF-8 sequence at byte i of text. For an ill-formed sequence, returns
---nil and the length of its longest valid prefix (at least 1), which a decoder replaces with one U+FFFD.
---@param text string
---@param i integer
---@return integer|nil length, integer? invalid_length
local function utf8_sequence_length(text, i)
  local lead = text:byte(i)
  local length, low, high
  if lead < 0x80 then
    return 1
  elseif lead >= 0xC2 and lead <= 0xDF then
    length, low, high = 2, 0x80, 0xBF
  elseif lead == 0xE0 then
    length, low, high = 3, 0xA0, 0xBF -- no overlong forms
  elseif lead == 0xED then
    length, low, high = 3, 0x80, 0x9F -- no surrogates
  elseif lead >= 0xE1 and lead <= 0xEF then
    length, low, high = 3, 0x80, 0xBF
  elseif lead == 0xF0 then
    length, low, high = 4, 0x90, 0xBF -- no overlong forms
  elseif lead >= 0xF1 and lead <= 0xF3 then
    length, low, high = 4, 0x80, 0xBF
  elseif lead == 0xF4 then
    length, low, high = 4, 0x80, 0x8F -- nothing above U+10FFFF
  else
    return nil, 1
  end
  for offset = 1, length - 1 do
    local byte = text:byte(i + offset)
    if not byte or byte < low or byte > high then
      return nil, offset
    end
    low, high = 0x80, 0xBF
  end
  return length
end

---Returns the byte index of the first byte of the code point that contains byte col of line. A mark keeps its
---byte column when text before it on the line changes, so `gv` can put the anchor inside a multibyte character.
---A continuation byte outside a well-formed sequence is a character of its own in Neovim and keeps its column.
---@param line string
---@param col integer
---@return integer
local function code_point_start(line, col)
  local byte = line:byte(col)
  if not byte or byte < 0x80 or byte > 0xBF then
    return col
  end
  -- A code point has at most three continuation bytes (0x80-0xBF) after its first byte.
  for lead = col - 1, math.max(col - 3, 1), -1 do
    byte = line:byte(lead)
    if byte < 0x80 or byte > 0xBF then
      local length = utf8_sequence_length(line, lead)
      return (length and lead + length > col) and lead or col
    end
  end
  return col
end

---Returns text with each ill-formed UTF-8 sequence replaced by U+FFFD. A buffer line can hold any bytes, and
---the client drops the connection when a message is not valid UTF-8.
---@param text string
---@return string
local function valid_utf8(text)
  local parts = {}
  local valid_from, i = 1, 1
  while i <= #text do
    local length, invalid_length = utf8_sequence_length(text, i)
    if length then
      i = i + length
    else
      table.insert(parts, text:sub(valid_from, i - 1))
      table.insert(parts, "\239\191\189")
      i = i + invalid_length
      valid_from = i
    end
  end
  table.insert(parts, text:sub(valid_from))
  return table.concat(parts)
end

---@param byte integer|nil
---@return boolean
local function is_ascii_control(byte)
  return byte ~= nil and (byte < 0x20 or byte == 0x7F)
end

---Returns the byte index of the last selected byte on the last line of a charwise or blockwise selection.
---Cutting inside a multibyte character would put invalid UTF-8 into selection_changed, so the selection takes
---the whole end character. With 'selection' set to exclusive, a selection of more than one position ends after
---the character before it instead.
---@param line string the selection's last line
---@param start_coords table
---@param end_coords table
---@return integer
local function selection_end_byte(line, start_coords, end_coords)
  local col = code_point_start(line, end_coords.col)
  local one_position = start_coords.lnum == end_coords.lnum and start_coords.col == col
  -- vim.fn passes a Lua string with a NUL byte as a Blob. Neovim keeps NUL as NL in a line, and both are one byte.
  line = line:gsub("%z", "\n")
  -- On Neovim 0.11+ an ASCII control character, such as a TAB, a NUL or an ESC, is a character of its own, and a
  -- composing character after it is the next character. The patterns below join the two.
  local control_alone = vim.fn.has("nvim-0.11") == 1
  if vim.o.selection == "exclusive" and not one_position then
    if control_alone and is_ascii_control(line:byte(col - 1)) then
      return col - 1
    end
    -- Neovim ends after the character before col. On 0.11+ that can be a cluster that reaches past col, such as
    -- स्ते when col is its त. Without a character before col, the selection ends at the line start.
    return math.max(vim.fn.matchend(line, "^\\_.*\\%<" .. col .. "c\\_."), 0)
  end
  if col > #line then
    return col
  end
  if control_alone and is_ascii_control(line:byte(col)) then
    return col
  end
  -- Match the character that starts at byte col, with its composing characters, and end after it. A pattern
  -- anchored at the column, like `\%13c.`, matches nothing when Neovim 0.11+ sees col inside a cluster, such
  -- as the त of स्ते, although the cursor can stand there. `\_.` also matches the NL.
  return vim.fn.matchend(line, "\\_.", col - 1)
end

---Handles an end past the last character of its line, which `v$` and `l` past the last character make. A charwise
---selection then includes the line break and ends at the start of the next line: Neovim yanks that line break, and
---VS Code ends such a selection there. Neovim yanks no line break after the buffer's last line, and a blockwise
---selection never includes one, so those end at the end of the line.
---@param bufnr integer
---@param visual_mode string
---@param lines_content string[] the selection's lines. The next line is appended when the end moves there.
---@param end_coords table
local function end_past_line(bufnr, visual_mode, lines_content, end_coords)
  local last_line = lines_content[#lines_content]
  if end_coords.col <= #last_line then
    return
  end
  if visual_mode == "v" and end_coords.lnum < vim.api.nvim_buf_line_count(bufnr) then
    end_coords.lnum = end_coords.lnum + 1
    end_coords.col = 0
    table.insert(lines_content, vim.api.nvim_buf_get_lines(bufnr, end_coords.lnum - 1, end_coords.lnum, false)[1])
  else
    end_coords.col = #last_line
  end
end

---Extracts text for linewise visual selection
---@param lines_content table - array of line strings
---@param start_coords table - start coordinates
---@return string text - the extracted text
local function extract_linewise_text(lines_content, start_coords)
  start_coords.col = 1 -- Linewise selection effectively starts at column 1
  return table.concat(lines_content, "\n")
end

---Extracts text for characterwise visual selection
---@param lines_content table - array of line strings
---@param start_coords table - start coordinates
---@param end_coords table - end coordinates
---@return string|nil text - the extracted text or nil if invalid
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

---Calculates LSP-compatible position coordinates
---@param start_coords table - start coordinates
---@param end_coords table - end coordinates
---@param visual_mode string - the visual mode character
---@param lines_content table - array of line strings
---@return table position - LSP position object with start and end fields
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

---Gets the current visual selection details.
---@return table|nil selection A table containing selection text, file path, URL, and
---start/end positions, or nil if no visual selection exists.
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
    -- Blockwise ("\22") is approximated as the contiguous charwise span: selection_changed
    -- carries a single start/end range and cannot represent a rectangular block. Proper
    -- per-column block extraction is a follow-up.
    start_coords.col = code_point_start(lines_content[1], start_coords.col)
    end_coords.col = selection_end_byte(lines_content[#lines_content], start_coords, end_coords)
    end_past_line(current_buf, visual_mode, lines_content, end_coords)
    final_text = extract_characterwise_text(lines_content, start_coords, end_coords)
    if not final_text then
      return nil
    end
  else
    return nil
  end

  local lsp_positions = calculate_lsp_positions(start_coords, end_coords, visual_mode, lines_content)

  return {
    text = valid_utf8(final_text),
    filePath = file_path,
    fileUrl = "file://" .. file_path,
    selection = {
      start = lsp_positions.start,
      ["end"] = lsp_positions["end"],
      isEmpty = (not final_text or #final_text == 0),
    },
  }
end

---Gets the just-completed visual selection from the `'<` and `'>` marks.
---Unlike `get_visual_selection()`, this does NOT require the editor to currently be in
---visual mode, so it can be called from a `ModeChanged` (visual -> normal) handler where
---`nvim_get_mode()` already reports normal mode but the marks are still valid. The marks
---are always in chronological order (`'<` before `'>`).
---Only valid immediately on visual exit: it pairs the buffer-local `'<`/`'>` marks with the
---GLOBAL `vim.fn.visualmode()`, so both must describe the same just-completed selection
---(do not call it after an unrelated visual selection in another buffer).
---@return table|nil selection A selection table matching get_visual_selection()'s shape, or nil.
function M.get_visual_selection_from_marks()
  local visual_mode = vim.fn.visualmode()
  if not visual_mode or visual_mode == "" then
    return nil
  end

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  if start_pos[2] == 0 or end_pos[2] == 0 then
    return nil -- no recorded visual selection
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(current_buf)

  local start_coords = { lnum = start_pos[2], col = start_pos[3] }
  local end_coords = { lnum = end_pos[2], col = end_pos[3] }

  local lines_content = vim.api.nvim_buf_get_lines(
    current_buf,
    start_coords.lnum - 1, -- Convert to 0-indexed
    end_coords.lnum, -- nvim_buf_get_lines end is exclusive
    false
  )

  if #lines_content == 0 then
    return nil
  end

  -- For linewise selections (and `$`), the `'>` column can be MAXCOL (2147483647). Clamp it
  -- to the last line's length + 1 so it never overflows string.sub / LSP character math.
  local last_line = lines_content[#lines_content] or ""
  if end_coords.col > #last_line + 1 then
    end_coords.col = #last_line + 1
  end

  local final_text
  if visual_mode == "V" then
    final_text = extract_linewise_text(lines_content, start_coords)
  elseif visual_mode == "v" or visual_mode == "\22" then
    -- Blockwise ("\22") is approximated as the contiguous charwise span (matching
    -- get_visual_selection), since selection_changed carries a single start/end range and
    -- cannot represent a rectangular block. Proper per-column block extraction is a follow-up.
    start_coords.col = code_point_start(lines_content[1], start_coords.col)
    end_coords.col = selection_end_byte(last_line, start_coords, end_coords)
    end_past_line(current_buf, visual_mode, lines_content, end_coords)
    final_text = extract_characterwise_text(lines_content, start_coords, end_coords)
    if not final_text then
      return nil
    end
  else
    return nil
  end

  local lsp_positions = calculate_lsp_positions(start_coords, end_coords, visual_mode, lines_content)

  return {
    text = valid_utf8(final_text),
    filePath = file_path,
    fileUrl = "file://" .. file_path,
    selection = {
      start = lsp_positions.start,
      ["end"] = lsp_positions["end"],
      isEmpty = (not final_text or #final_text == 0),
    },
  }
end

---Flushes the just-completed visual selection synchronously when leaving visual mode.
---Captures the selection from the `'<`/`'>` marks, records it as the active visual
---selection, cancels any pending demotion, and broadcasts it if it changed. This closes
---the debounce race where a selection made and released faster than `debounce_ms` was
---never broadcast at all (issue #246). The Claude terminal buffer is ignored, mirroring
---`update_selection()`. Deduplicates against the last sent selection so a selection
---already broadcast by the in-visual debounce is not sent twice on exit. If the buffer
---was mutated while in visual mode (a consuming operator like d/c/>/x), the marks no
---longer describe the user's selection, so the flush is skipped to avoid broadcasting
---stale, post-edit text as a phantom selection.
function M.flush_visual_selection()
  if not M.state.tracking_enabled then
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  local buf_name = vim.api.nvim_buf_get_name(current_buf)

  if buf_name and buf_name:match("^term://") and buf_name:lower():find("claude", 1, true) then
    return
  end
  if terminal then
    local claude_term_bufnr = terminal.get_active_terminal_bufnr()
    if claude_term_bufnr and current_buf == claude_term_bufnr then
      return
    end
  end

  -- Skip when the buffer was edited while in visual mode: the changedtick advancing since
  -- visual entry means an operator (d/c/x...) consumed the selection, so the '<,'> marks
  -- point at post-edit text the user never selected. This is intentionally conservative --
  -- it also skips in-place transforms that leave a valid selection (gU/gu/~/J/=), because
  -- they cannot be told apart from consuming operators by the marks alone (both leave a
  -- non-empty, in-bounds region). Such fast transforms simply are not flushed; the prior
  -- behavior never broadcast them either (they lost the debounce race), so this is a
  -- residual non-broadcast, not a regression.
  local entry = M.state.visual_entry
  if entry and entry.bufnr == current_buf and vim.api.nvim_buf_get_changedtick(current_buf) ~= entry.tick then
    return
  end

  local selection = M.get_visual_selection_from_marks()
  if not selection or selection.selection.isEmpty then
    return
  end

  -- Record the cursor position at flush time so demotion only fires after a real move.
  M.state.cursor_at_flush = { bufnr = current_buf, pos = vim.api.nvim_win_get_cursor(0) }
  M.state.last_active_visual_selection = {
    bufnr = current_buf,
    selection_data = vim.deepcopy(selection),
    timestamp = vim.loop.now(),
  }

  M._cancel_demotion_timer()

  if M.has_selection_changed(selection) then
    M.state.latest_selection = selection
    if M.server then
      M.send_selection_update(selection)
    end
  end
end

---Gets the current cursor position when no visual selection is active.
---@return table A table containing an empty text, file path, URL, and cursor
---position as start/end, with isEmpty set to true.
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

---Checks if the selection has changed compared to the latest stored selection.
---@param new_selection table|nil The new selection object to compare.
---@return boolean changed true if the selection has changed, false otherwise.
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

---Sends the selection update to the Claude server.
---@param selection table The selection object to send.
function M.send_selection_update(selection)
  M.server.broadcast("selection_changed", selection)
end

---Gets the latest recorded selection.
---@return table|nil The latest selection object, or nil if none recorded.
function M.get_latest_selection()
  return M.state.latest_selection
end

---Sends the current selection to Claude.
---This function is typically invoked by a user command. It forces an immediate
---update and sends the latest selection.
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

---Gets selection from range marks (e.g., when using :'<,'> commands)
---@param line1 number The start line (1-indexed)
---@param line2 number The end line (1-indexed)
---@return table|nil A table containing selection text, file path, URL, and
---start/end positions, or nil if invalid range
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

---Sends an at_mentioned notification for the current visual selection.
---@param line1 number|nil Optional start line for range-based selection
---@param line2 number|nil Optional end line for range-based selection
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

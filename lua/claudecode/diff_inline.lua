--- Inline diff module for Claude Code Neovim integration.
-- Provides a VS Code-style unified inline diff view with deleted (red/strikethrough)
-- and added (green) lines interleaved in a single persistent buffer.
local M = {}

local logger = require("claudecode.logger")

local ns = vim.api.nvim_create_namespace("claudecode_inline_diff")

--- Name of the single persistent buffer used for every unified diff.
local CLAUDE_BUFFER_NAME = "ClaudeCodeBuffer"

--- Bumped to cancel in-flight animations
local reveal_gen = 0

--- Queue of pending diffs waiting for acceptance
--- Each entry: { params, callback, config }
local diff_queue = {}

--- Currently active (pending) diff tab_name, or nil if none
local current_diff_tab = nil

---Get the persistent ClaudeCodeBuffer, creating it on first use or resetting it for reuse.
---The buffer is kept alive (`bufhidden = "hide"`) so it survives window/tab closes.
---@return number buf The buffer handle
local function get_or_create_claudecode_buffer()
  local existing = vim.fn.bufnr(CLAUDE_BUFFER_NAME)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    pcall(function()
      vim.api.nvim_buf_set_option(existing, "modifiable", true)
      vim.api.nvim_buf_clear_namespace(existing, ns, 0, -1)
      vim.api.nvim_buf_set_lines(existing, 0, -1, false, {})
      vim.api.nvim_buf_set_option(existing, "buftype", "acwrite")
      vim.api.nvim_buf_set_option(existing, "bufhidden", "hide")
      vim.b[existing].claudecode_inline_diff = nil
      vim.b[existing].claudecode_diff_tab_name = nil
    end)
    return existing
  end

  local b = vim.api.nvim_create_buf(false, true)
  if b == 0 then
    error({ code = -32000, message = "Buffer creation failed", data = "Could not create ClaudeCodeBuffer" })
  end
  pcall(vim.api.nvim_buf_set_name, b, CLAUDE_BUFFER_NAME)
  vim.api.nvim_buf_set_option(b, "buftype", "acwrite")
  vim.api.nvim_buf_set_option(b, "bufhidden", "hide")
  return b
end

---Resolve the diff function. Neovim 0.12 renamed `vim.diff` to `vim.text.diff`.
---@return function|nil
local function get_diff_fn()
  return (vim.text and vim.text.diff) or vim.diff
end

---Setup highlight groups for added/deleted lines.
local function setup_highlights()
  vim.api.nvim_set_hl(0, "ClaudeCodeInlineDiffAdd", { bg = "#2a4a2a", default = true })
  vim.api.nvim_set_hl(0, "ClaudeCodeInlineDiffDelete", { bg = "#4a2a2a", strikethrough = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeCodeInlineDiffAddSign", { fg = "#98c379", default = true })
  vim.api.nvim_set_hl(0, "ClaudeCodeInlineDiffDeleteSign", { fg = "#e06c75", default = true })
end

-- ── Pure functions (testable in isolation) ────────────────────────

--- Split a string into lines, removing a trailing empty line from a final newline.
---@param text string
---@return string[]
local function split_lines(text)
  if text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Compute an interleaved inline diff from two strings.
---@param old_text string Original file content
---@param new_text string Proposed file content
---@return string[] lines Buffer lines for display
---@return string[] line_types Parallel array of "unchanged"|"added"|"deleted"
function M.compute_inline_diff(old_text, new_text)
  old_text = old_text or ""
  new_text = new_text or ""

  local hunks = get_diff_fn()(old_text, new_text, { result_type = "indices" }) or {}
  local old_lines = split_lines(old_text)
  local new_lines = split_lines(new_text)

  local result_lines = {}
  local result_types = {}
  local old_pos = 1
  local new_pos = 1

  for _, hunk in ipairs(hunks) do
    local start_a, count_a, _, count_b = hunk[1], hunk[2], hunk[3], hunk[4]

    local unchanged_count
    if count_a > 0 then
      unchanged_count = start_a - old_pos
    else
      unchanged_count = start_a - old_pos + 1
    end

    for _ = 1, unchanged_count do
      result_lines[#result_lines + 1] = new_lines[new_pos]
      result_types[#result_types + 1] = "unchanged"
      old_pos = old_pos + 1
      new_pos = new_pos + 1
    end

    for _ = 1, count_a do
      result_lines[#result_lines + 1] = old_lines[old_pos]
      result_types[#result_types + 1] = "deleted"
      old_pos = old_pos + 1
    end

    for _ = 1, count_b do
      result_lines[#result_lines + 1] = new_lines[new_pos]
      result_types[#result_types + 1] = "added"
      new_pos = new_pos + 1
    end
  end

  while new_pos <= #new_lines do
    result_lines[#result_lines + 1] = new_lines[new_pos]
    result_types[#result_types + 1] = "unchanged"
    new_pos = new_pos + 1
  end

  return result_lines, result_types
end

--- Collect only "unchanged" + "added" lines (the accepted new content).
---@param lines string[] Buffer lines
---@param line_types string[] Parallel type array
---@return string content The accepted content joined with newlines
function M.extract_new_content(lines, line_types)
  local out = {}
  for i, lt in ipairs(line_types) do
    if lt ~= "deleted" then
      out[#out + 1] = lines[i]
    end
  end
  return table.concat(out, "\n")
end

-- ── Rendering ─────────────────────────────────────────────────────

--- Apply the add/delete highlight + sign extmark for a single line.
---@param buf number Buffer handle
---@param index number 1-based line index
---@param line_type string "added" | "deleted" | "unchanged"
--- Apply the add/delete highlight + sign extmark for a single line.
---@param buf number Buffer handle
---@param index number 1-based line index
---@param line_type string "added" | "deleted" | "unchanged"
---@return number|nil extmark id (nil for unchanged)
local function apply_line_mark(buf, index, line_type)
  if line_type == "added" then
    return vim.api.nvim_buf_set_extmark(buf, ns, index - 1, 0, {
      line_hl_group = "ClaudeCodeInlineDiffAdd",
      sign_text = "+",
      sign_hl_group = "ClaudeCodeInlineDiffAddSign",
    })
  elseif line_type == "deleted" then
    return vim.api.nvim_buf_set_extmark(buf, ns, index - 1, 0, {
      line_hl_group = "ClaudeCodeInlineDiffDelete",
      sign_text = "-",
      sign_hl_group = "ClaudeCodeInlineDiffDeleteSign",
    })
  end
end

--- Render the full diff into `buf` and apply add/delete highlights + signs.
---@param buf number Buffer handle
---@param lines string[] Lines to set
---@param line_types string[] Parallel type array
function M.render_diff_buffer(buf, lines, line_types)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for i, lt in ipairs(line_types) do
    apply_line_mark(buf, i, lt)
  end
end

---@param wpm number Words per minute
local function wpm_to_ms_per_char(wpm)
  return (60.0 / wpm / 5.0) * 1000.0
end

--- Progressively reveal `lines` in `buf` with a natural "typing" cadence.
---O(n) incremental, cancellable via `reveal_gen`.
---@param buf number Buffer handle
---@param lines string[] Full diff lines
---@param line_types string[] Parallel type array
---@param opts table|nil { delay_ms:number, chars_per_tick:number }
local function render_diff_buffer_streamed(buf, lines, line_types, opts)
  opts = opts or {}
  local chars_per_tick = math.max(1, opts.chars_per_tick or 1)
  local delay_floor_ms = math.max(0, opts.delay_ms or 0)

  vim.api.nvim_buf_set_option(buf, "modifiable", true)

  reveal_gen = reveal_gen + 1
  local my_gen = reveal_gen

  -- Unchanged lines are shown instantly; added/deleted lines start empty and are
  -- typed out one character at a time so only the *changed* lines animate.
  local initial = {}
  for i, lt in ipairs(line_types) do
    initial[i] = (lt == "unchanged") and lines[i] or ""
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial)

  -- Apply the add/delete background + sign marks immediately (track ids so we can
  -- re-anchor them after each in-place line update — replacing a marked line with
  -- nvim_buf_set_lines shifts the extmark down by one and corrupts positions).
  local mark_ids = {}
  for i, lt in ipairs(line_types) do
    if lt ~= "unchanged" then
      mark_ids[i] = apply_line_mark(buf, i, lt)
    end
  end

  -- Collect changed line indices in document order.
  local changed = {}
  for i, lt in ipairs(line_types) do
    if lt ~= "unchanged" then
      changed[#changed + 1] = i
    end
  end

  local idx = 1
  local filled = {}
  for _, ci in ipairs(changed) do
    filled[ci] = ""
  end

  -- Re-anchor the extmark for line `ci` at its correct row. nvim_buf_set_lines
  -- moves the mark down by one, so we delete by id and recreate it.
  local function reanchor(ci)
    local old_id = mark_ids[ci]
    if old_id then
      pcall(vim.api.nvim_buf_del_extmark, buf, ns, old_id)
    end
    mark_ids[ci] = apply_line_mark(buf, ci, line_types[ci])
  end

  local function step()
    if my_gen ~= reveal_gen then
      return
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_set_option, buf, "modifiable", false)
      return
    end
    if idx > #changed then
      pcall(vim.api.nvim_buf_set_option, buf, "modifiable", false)
      return
    end

    local ci = changed[idx]
    local target = lines[ci] or ""
    local cur = filled[ci] or ""

    if #cur >= #target then
      -- This changed line is complete; move on to the next one.
      idx = idx + 1
      -- Tail-call via defer so we don't blow the stack on many changed lines.
      vim.defer_fn(step, 0)
      return
    end

    local adv = math.min(chars_per_tick, #target - #cur)
    local next_text = target:sub(1, #cur + adv)
    filled[ci] = next_text
    pcall(vim.api.nvim_buf_set_lines, buf, ci - 1, ci, false, { next_text })
    reanchor(ci)

    local wpm = math.random(400, 1000)
    vim.defer_fn(step, math.max(delay_floor_ms, math.floor(wpm_to_ms_per_char(wpm))))
  end

  step()
end

--- Cancel any in-flight streaming animation.
local function cancel_animation()
  reveal_gen = reveal_gen + 1
end

--- Move `win`'s cursor to the buffer's first changed line and center it.
--- No-op if the window is invalid or no change line was recorded.
---@param buf number Buffer handle
---@param win number|nil Window handle showing `buf`
local function scroll_to_first_change(buf, win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local line = vim.b[buf].claudecode_first_change_line
  if not line then
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)
  line = math.max(1, math.min(line, count))
  pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! zz")
  end)
end

--- Create a scratch editor window when the current tab only has terminal/sidebar
--- windows, giving the diff split something to anchor to. Returns the new window.
---@return number win_id
local function create_fallback_editor_window()
  vim.cmd("rightbelow vsplit")
  local fallback_win = vim.api.nvim_get_current_win()

  local ok, err = pcall(function()
    local scratch_buf = vim.api.nvim_create_buf(false, true)
    if scratch_buf == 0 then
      error({ code = -32000, message = "Buffer creation failed", data = "Could not create fallback editor buffer" })
    end
    vim.api.nvim_buf_set_option(scratch_buf, "bufhidden", "wipe")
    vim.api.nvim_win_set_buf(fallback_win, scratch_buf)
  end)

  if not ok then
    if fallback_win and vim.api.nvim_win_is_valid(fallback_win) then
      pcall(vim.api.nvim_win_close, fallback_win, true)
    end
    error(err)
  end

  return fallback_win
end

--- Clean up inline diff resources if setup fails before state registration.
---@param tab_name string Diff identifier
---@param partial table Partially created resources
local function cleanup_unregistered_inline_setup(tab_name, partial)
  -- Always clear the pending marker so a failed setup can't wedge the queue.
  current_diff_tab = nil
  local diff = require("claudecode.diff")
  if diff._get_active_diffs()[tab_name] then
    diff._cleanup_diff_state(tab_name, "setup failed")
    return
  end
  for _, autocmd_id in ipairs(partial.autocmd_ids or {}) do
    pcall(vim.api.nvim_del_autocmd, autocmd_id)
  end
  -- Close any windows opened before the failure (diff split + terminal-only fallback).
  if partial.diff_window and vim.api.nvim_win_is_valid(partial.diff_window) then
    pcall(vim.api.nvim_win_close, partial.diff_window, true)
  end
  if partial.fallback_window and vim.api.nvim_win_is_valid(partial.fallback_window) then
    pcall(vim.api.nvim_win_close, partial.fallback_window, true)
  end
  if partial.new_buffer and vim.api.nvim_buf_is_valid(partial.new_buffer) then
    pcall(vim.api.nvim_buf_delete, partial.new_buffer, { force = true })
  end
end

-- ── Setup ─────────────────────────────────────────────────────────

--- Prepare the unified diff in ClaudeCodeBuffer and show it in a split in the
--- current tab (reusing an existing ClaudeCodeBuffer window if one is open).
---@param params table Diff parameters (old_file_path, new_file_path, new_file_contents, tab_name)
---@param resolution_callback function Callback to call when diff resolves
---@param config table Plugin configuration
function M.setup_inline_diff(params, resolution_callback, config)
  local diff = require("claudecode.diff")

  local autocmd_ids = {}
  local buf = nil
  local partial_setup = {
    new_buffer = nil,
    diff_window = nil,
    fallback_window = nil,
    autocmd_ids = autocmd_ids,
  }

  local function guard(action)
    local results = { pcall(action) }
    if not results[1] then
      cleanup_unregistered_inline_setup(params.tab_name, partial_setup)
      error(results[2])
    end
    return unpack(results, 2)
  end

  if not get_diff_fn() then
    error({
      code = -32000,
      message = "Inline diff requires Neovim >= 0.9.0",
      data = "vim.text.diff()/vim.diff() is not available.",
    })
  end

  setup_highlights()

  local tab_name = params.tab_name

  -- Serial queue: if a diff is already pending/active, queue this one WITHOUT
  -- touching the active buffer or its state. This prevents tearing down an
  -- in-progress diff when multiple openDiff calls arrive (e.g. Claude opening
  -- several files at once), which previously corrupted state and surfaced as a
  -- persistent "Diff setup failed" error.
  if current_diff_tab ~= nil then
    table.insert(diff_queue, {
      params = params,
      callback = resolution_callback,
      config = config,
    })
    logger.debug("diff", "Queued inline diff (already pending:", current_diff_tab .. ")")
    return
  end

  -- Treat unreadable/missing original paths as new files (never throw on the
  -- existence probe, which is what triggered setup failures for new files).
  local readable_ok, exists = pcall(function()
    return vim.fn.filereadable(params.old_file_path) == 1
  end)
  local old_file_exists = readable_ok and exists or false
  local is_new_file = not old_file_exists

  if old_file_exists then
    local is_dirty = false
    local dirty_ok, dirty = pcall(diff._is_buffer_dirty, params.old_file_path)
    if dirty_ok then
      is_dirty = dirty
    end
    if is_dirty then
      error({
        code = -32000,
        message = "Cannot create diff: file has unsaved changes",
        data = "Please save (:w) or discard (:e!) changes to " .. params.old_file_path,
      })
    end
  end

  local old_text = ""
  if not is_new_file then
    local f = io.open(params.old_file_path, "r")
    if f then
      old_text = f:read("*a") or ""
      f:close()
    else
      error({ code = -32000, message = "Failed to read original file", data = params.old_file_path })
    end
  end

  local ok_diff, lines, line_types = pcall(M.compute_inline_diff, old_text, params.new_file_contents)
  if not ok_diff then
    error({ code = -32000, message = "Failed to compute inline diff", data = tostring(lines) })
  end

  buf = guard(get_or_create_claudecode_buffer)
  partial_setup.new_buffer = buf

  -- Cancel any in-flight animation from a previous diff before rendering.
  cancel_animation()

  -- Render (streaming or static) - no window opened. Guarded so a render failure
  -- runs cleanup instead of escaping with a half-built diff.
  guard(function()
    if config and config.diff_opts and config.diff_opts.stream_reveal then
      render_diff_buffer_streamed(buf, lines, line_types, {
        delay_ms = config.diff_opts.stream_reveal_delay_ms or 0,
        chars_per_tick = config.diff_opts.stream_reveal_chars_per_tick or 10,
      })
    else
      M.render_diff_buffer(buf, lines, line_types)
      vim.api.nvim_buf_set_option(buf, "modifiable", false)
    end
  end)

  -- Mark this diff as current only after a successful render, so a setup that
  -- throws above never leaves a stale pending marker that queues every future
  -- diff behind a dead one. (Safe: setup is synchronous, so no other openDiff
  -- can arrive before this returns.)
  current_diff_tab = tab_name

  vim.b[buf].claudecode_diff_tab_name = tab_name
  vim.b[buf].claudecode_inline_diff = true

  -- Record the first changed line so any window showing the buffer can jump to it.
  local first_change = nil
  for i, lt in ipairs(line_types) do
    if lt ~= "unchanged" then
      first_change = i
      break
    end
  end
  vim.b[buf].claudecode_first_change_line = first_change

  local ft_ok, ft = pcall(diff._detect_filetype, params.new_file_path)
  if ft_ok and ft and ft ~= "" then
    vim.api.nvim_set_option_value("filetype", ft, { buf = buf })
  end

  -- Show the buffer in a split in the CURRENT tab. Reuse an existing
  -- ClaudeCodeBuffer window if one is already open (e.g. from a prior diff or a
  -- queued one); otherwise split off the main editor window. In a terminal-only
  -- tab (no editor window) create a throwaway scratch window to anchor the split.
  local editor_win, fallback_window, diff_win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      diff_win = w
      break
    end
  end
  if not diff_win then
    editor_win = diff._find_main_editor_window()
    if not editor_win then
      fallback_window = guard(create_fallback_editor_window)
      partial_setup.fallback_window = fallback_window
      editor_win = fallback_window
    end
    guard(function()
      assert(editor_win and vim.api.nvim_win_is_valid(editor_win), "ClaudeCode unified diff target window must be valid")
      vim.api.nvim_set_current_win(editor_win)
      vim.cmd("rightbelow vsplit")
      diff_win = vim.api.nvim_get_current_win()
      partial_setup.diff_window = diff_win
      vim.api.nvim_win_set_buf(diff_win, buf)
    end)
  end
  pcall(vim.api.nvim_set_option_value, "signcolumn", "yes", { win = diff_win })
  pcall(vim.cmd, "wincmd =")

  -- Register state
  guard(function()
    local aug = diff._get_autocmd_group()
    autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = aug,
      buffer = buf,
      callback = function()
        diff._resolve_diff_as_saved(tab_name, buf)
        return true
      end,
    })
    -- Reject only on real buffer destruction (:bd/:bw). We deliberately do NOT
    -- reject on WinClosed: with bufhidden="hide" the persistent ClaudeCodeBuffer
    -- is meant to be freely opened/hidden (e.g. via toggle_inline_diff), so
    -- closing its window must only hide it — never send DIFF_REJECTED. Rejection
    -- is explicit (ClaudeCodeDiffDeny) or via actual buffer deletion.
    for _, ev in ipairs({ "BufDelete", "BufWipeout" }) do
      autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd(ev, {
        group = aug,
        buffer = buf,
        callback = function()
          diff._resolve_diff_as_rejected(tab_name)
        end,
      })
    end
    diff._register_diff_state(tab_name, {
      old_file_path = params.old_file_path,
      new_file_path = params.new_file_path,
      new_file_contents = params.new_file_contents,
      old_file_contents = old_text,
      new_buffer = buf,
      new_window = diff_win,
      target_window = editor_win,
      fallback_window = fallback_window,
      lines = lines,
      line_types = line_types,
      is_new_file = is_new_file,
      autocmd_ids = autocmd_ids,
      created_at = vim.fn.localtime(),
      status = "pending",
      resolution_callback = resolution_callback,
      result_content = nil,
      layout = "unified",
      client_id = params.client_id,
    })
  end)

  -- Jump to the first change in the diff window.
  scroll_to_first_change(buf, diff_win)
end

-- ── User commands ────────────────────────────────────────────────

---Open ClaudeCodeBuffer in the current tab. Creates a vsplit if not already shown.
---If buffer doesn't exist yet, creates an empty one (for toggle-anytime use).
---@param tab_name string|nil Optional tab_name to link the window to
function M.open_inline_diff(tab_name)
  local buf = vim.fn.bufnr(CLAUDE_BUFFER_NAME)
  if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, CLAUDE_BUFFER_NAME)
    vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
  end

  local win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      win = w
      break
    end
  end

  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("rightbelow vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    pcall(vim.api.nvim_set_option_value, "signcolumn", "yes", { win = win })
    vim.cmd("wincmd =")
  end

  if tab_name then
    local diff = require("claudecode.diff")
    local diff_data = diff._get_active_diffs()[tab_name]
    if diff_data and vim.api.nvim_win_is_valid(win) then
      diff_data.new_window = win
    end
  end

  scroll_to_first_change(buf, win)
end

---Toggle ClaudeCodeBuffer: close if visible in current tab, open otherwise.
---Creates an empty buffer if none exists (for anytime toggle use).
function M.toggle_inline_diff()
  local buf = vim.fn.bufnr(CLAUDE_BUFFER_NAME)
  if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == buf then
        pcall(vim.api.nvim_win_close, win, false)
        return
      end
    end
  end
  -- Buffer doesn't exist or not visible in this tab - open it
  M.open_inline_diff()
end

---Close the inline diff buffer window (alias for toggle for backwards compatibility).
function M.close_inline_diff()
  M.toggle_inline_diff()
end

-- ── Resolution & Cleanup ─────────────────────────────────────────

--- Resolve an inline diff as saved (user accepted changes).
---@param tab_name string The diff identifier
---@param diff_data table The diff state data
function M.resolve_inline_as_saved(tab_name, diff_data)
  logger.debug("diff", "Accepting inline diff for", tab_name)
  local content = M.extract_new_content(diff_data.lines, diff_data.line_types)
  if diff_data.new_file_contents:sub(-1) == "\n" and content:sub(-1) ~= "\n" then
    content = content .. "\n"
  end
  local result = {
    content = { { type = "text", text = "FILE_SAVED" }, { type = "text", text = content } },
  }
  diff_data.status = "saved"
  diff_data.result_content = result
  if diff_data.resolution_callback then
    diff_data.resolution_callback(result)
  end

  -- Release this diff's autocmds + state (keep the reused buffer + window) so the
  -- next queued diff can take over the same buffer cleanly without duplicate autocmds.
  M._release_inline_diff_state(tab_name)

  if #diff_queue > 0 then
    -- Advance to the next queued diff after acceptance.
    vim.schedule(function()
      M._process_next_queued_diff()
    end)
  else
    -- Last diff in the queue: perform final buffer cleanup (reload the accepted
    -- file into the persistent buffer; the window stays open via bufhidden="hide").
    M.cleanup_inline_diff(tab_name, diff_data)
  end
end

--- Resolve an inline diff as rejected.
---@param tab_name string The diff identifier
---@param diff_data table The diff state data
function M.resolve_inline_as_rejected(tab_name, diff_data)
  diff_data.status = "rejected"
  diff_data.result_content = {
    content = { { type = "text", text = "DIFF_REJECTED" }, { type = "text", text = tab_name } },
  }
  if diff_data.resolution_callback then
    diff_data.resolution_callback(diff_data.result_content)
  end
  -- Reject: stop the queue entirely (do NOT advance to the next diff), per design.
  -- Resolve every queued diff as rejected too, otherwise their blocking openDiff
  -- MCP calls never get a response and Claude hangs indefinitely.
  for _, queued in ipairs(diff_queue) do
    if queued.callback then
      pcall(queued.callback, {
        content = {
          { type = "text", text = "DIFF_REJECTED" },
          { type = "text", text = queued.params.tab_name },
        },
      })
    end
  end
  diff_queue = {}
  current_diff_tab = nil
  cancel_animation()
  -- Clean up via the diff module so active state is fully released while the
  -- persistent buffer is reloaded; the window stays open (bufhidden="hide").
  local diff = require("claudecode.diff")
  diff._cleanup_diff_state(tab_name, "diff rejected")
end

--- Release a diff's autocmds and active state WITHOUT touching the reused buffer
--- or its window. Used between queued diffs so the next setup starts from a clean
--- state on the same persistent buffer.
---@param tab_name string The diff identifier
function M._release_inline_diff_state(tab_name)
  local diff = require("claudecode.diff")
  local active = diff._get_active_diffs()
  local data = active[tab_name]
  if data then
    for _, autocmd_id in ipairs(data.autocmd_ids or {}) do
      pcall(vim.api.nvim_del_autocmd, autocmd_id)
    end
    active[tab_name] = nil
  end
  current_diff_tab = nil
end

--- Clean up an inline diff's state and UI.
---Keeps the window open and loads the reviewed file content (persistent buffer behavior).
---@param tab_name string The diff identifier
---@param diff_data table The diff state data
function M.cleanup_inline_diff(tab_name, diff_data)
  local diff = require("claudecode.diff")

  -- Stop any in-flight typing animation so it can't clobber the reloaded file view.
  cancel_animation()

  for _, autocmd_id in ipairs(diff_data.autocmd_ids or {}) do
    pcall(vim.api.nvim_del_autocmd, autocmd_id)
  end

  -- Close the throwaway scratch window created for a terminal-only tab; the diff
  -- window itself stays open (persistent buffer). No-op when no fallback was made.
  if diff_data.fallback_window and vim.api.nvim_win_is_valid(diff_data.fallback_window) then
    pcall(vim.api.nvim_win_close, diff_data.fallback_window, false)
  end

  -- Keep the ClaudeCodeBuffer open, showing plain file content (no diff markup).
  -- The buffer must reflect what actually happened to the file:
  --   * Explicit accept (`:w`, status "saved"): show the proposed content. We
  --     trust new_file_contents and do NOT read the file — Claude may not have
  --     written it yet, so a disk read here would be stale.
  --   * Otherwise (explicit reject, or a Claude-side accept that arrives as a
  --     pending close and is marked "rejected"): show the original immediately,
  --     then reconcile from disk once Claude has finished writing. Disk is the
  --     source of truth — new content if the change was applied, original if not.
  -- (do NOT close the window)
  local accepted = diff_data.status == "saved"
  if diff_data.new_buffer and vim.api.nvim_buf_is_valid(diff_data.new_buffer) then
    local b = diff_data.new_buffer
    pcall(function()
      vim.api.nvim_buf_set_option(b, "modifiable", true)
      vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
      local content = accepted and (diff_data.new_file_contents or "") or (diff_data.old_file_contents or "")
      vim.api.nvim_buf_set_lines(b, 0, -1, false, split_lines(content))
      vim.api.nvim_buf_set_option(b, "buftype", "nofile")
      vim.api.nvim_buf_set_option(b, "bufhidden", "hide")
      vim.api.nvim_buf_set_option(b, "modifiable", false)
      vim.b[b].claudecode_inline_diff = nil
      vim.b[b].claudecode_diff_tab_name = nil
      local ft_ok, ft = pcall(diff._detect_filetype, diff_data.new_file_path or diff_data.old_file_path)
      if ft_ok and ft and ft ~= "" then
        vim.api.nvim_set_option_value("filetype", ft, { buf = b })
      end
    end)

    -- Non-accept path: reconcile from disk after Claude's async write lands, so a
    -- Claude-side accept (written file, pending close) ends up showing the new
    -- content rather than the stale original. A genuine reject leaves the file
    -- unchanged, so this is a no-op there.
    if not accepted then
      local path = diff_data.old_file_path
      vim.defer_fn(function()
        if not (path and vim.api.nvim_buf_is_valid(b)) then
          return
        end
        if vim.fn.filereadable(path) ~= 1 then
          return
        end
        local fh = io.open(path, "r")
        if not fh then
          return
        end
        local disk = fh:read("*a") or ""
        fh:close()
        pcall(function()
          vim.api.nvim_buf_set_option(b, "modifiable", true)
          vim.api.nvim_buf_set_lines(b, 0, -1, false, split_lines(disk))
          vim.api.nvim_buf_set_option(b, "modifiable", false)
        end)
      end, 150)
    end
  end

  -- Clear current diff marker
  current_diff_tab = nil

  logger.debug("diff", "Cleaned up inline diff for", tab_name)
end

--- Process the next queued diff after the current one is resolved.
--- Called after acceptance to show the next file's changes.
function M._process_next_queued_diff()
  if #diff_queue == 0 then return end

  local next = table.remove(diff_queue, 1)
  if not next then return end

  -- setup_inline_diff shows the buffer itself (reusing an open ClaudeCodeBuffer
  -- window in the current tab, or splitting a new one), so no separate open here.
  local ok, err = pcall(M.setup_inline_diff, next.params, next.callback, next.config)
  if not ok then
    logger.error("diff", "Failed to set up queued diff:", tostring(err))
    -- Don't stall the queue on a single bad diff - keep draining it.
    vim.schedule(function()
      M._process_next_queued_diff()
    end)
  end
end

return M
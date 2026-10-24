--- Inline diff module for Claude Code Neovim integration.
-- Provides a VS Code-style unified inline diff view with deleted (red/strikethrough)
-- and added (green) lines interleaved in a single persistent buffer.
local M = {}

local logger = require("claudecode.logger")

local ns = vim.api.nvim_create_namespace("claudecode_inline_diff")

--- Name of the single persistent buffer used for every unified diff. It is reused
--- across diffs (cleared and re-rendered) instead of being wiped on accept/reject,
--- so it always stays open showing the file whose changes were reviewed.
local CLAUDE_BUFFER_NAME = "ClaudeCodeBuffer"

--- Bumped whenever a reveal starts or the diff is torn down, so any in-flight
--- streaming animation stops and does not mutate the buffer.
local reveal_gen = 0

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
  vim.api.nvim_buf_set_name(b, CLAUDE_BUFFER_NAME)
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
local function apply_line_mark(buf, index, line_type)
  if line_type == "added" then
    vim.api.nvim_buf_set_extmark(buf, ns, index - 1, 0, {
      line_hl_group = "ClaudeCodeInlineDiffAdd",
      sign_text = "+",
      sign_hl_group = "ClaudeCodeInlineDiffAddSign",
    })
  elseif line_type == "deleted" then
    vim.api.nvim_buf_set_extmark(buf, ns, index - 1, 0, {
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
--- O(n) incremental, cancellable via `reveal_gen`.
---@param buf number Buffer handle
---@param lines string[] Full diff lines
---@param line_types string[] Parallel type array
---@param opts table|nil { delay_ms:number, chars_per_tick:number }
local function render_diff_buffer_streamed(buf, lines, line_types, opts)
  opts = opts or {}
  local chars_per_tick = math.max(1, opts.chars_per_tick or 1)
  local delay_floor_ms = math.max(0, opts.delay_ms or 0)

  local full = table.concat(lines, "\n")
  local len = #full
  if len == 0 then
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    return
  end

  reveal_gen = reveal_gen + 1
  local my_gen = reveal_gen
  local buf_lines = { "" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, buf_lines)
  local committed = 0
  local marked_count = 0

  local function reveal_up_to(target_pos)
    target_pos = math.min(len, target_pos)
    if target_pos <= committed then
      return
    end

    local delta = full:sub(committed + 1, target_pos)
    committed = target_pos

    local parts = vim.split(delta, "\n", { plain = true })
    buf_lines[#buf_lines] = buf_lines[#buf_lines] .. parts[1]
    for k = 2, #parts do
      buf_lines[#buf_lines + 1] = parts[k]
    end

    local tail_from = #buf_lines - #parts + 1
    vim.api.nvim_buf_set_lines(buf, tail_from - 1, -1, false, vim.list_slice(buf_lines, tail_from))

    local complete_count
    if committed >= len then
      complete_count = (#buf_lines > 0 and buf_lines[#buf_lines] == "") and (#buf_lines - 1) or #buf_lines
    else
      complete_count = math.max(0, #buf_lines - 1)
    end
    complete_count = math.min(complete_count, #line_types)

    for i = marked_count + 1, complete_count do
      apply_line_mark(buf, i, line_types[i])
    end
    marked_count = complete_count
  end

  local function tick()
    if my_gen ~= reveal_gen then
      return
    end
    if not vim.api.nvim_buf_is_valid(buf) or committed >= len then
      vim.api.nvim_buf_set_option(buf, "modifiable", false)
      return
    end

    reveal_up_to(committed + chars_per_tick)
    if committed >= len or not vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_set_option(buf, "modifiable", false)
      return
    end

    local wpm = math.random(400, 1000)
    vim.defer_fn(tick, math.max(delay_floor_ms, math.floor(wpm_to_ms_per_char(wpm))))
  end

  tick()
end

--- Clean up inline diff resources if setup fails before state registration.
---@param tab_name string Diff identifier
---@param partial table Partially created resources
local function cleanup_unregistered_inline_setup(tab_name, partial)
  local diff = require("claudecode.diff")
  if diff._get_active_diffs()[tab_name] then
    diff._cleanup_diff_state(tab_name, "setup failed")
    return
  end
  for _, autocmd_id in ipairs(partial.autocmd_ids or {}) do
    pcall(vim.api.nvim_del_autocmd, autocmd_id)
  end
  if partial.new_buffer and vim.api.nvim_buf_is_valid(partial.new_buffer) then
    pcall(vim.api.nvim_buf_delete, partial.new_buffer, { force = true })
  end
end

-- ── Setup ─────────────────────────────────────────────────────────

--- Prepare the unified diff in ClaudeCodeBuffer without auto-opening a window.
--- Call `open_inline_diff()` to show the buffer wherever you want.
---@param params table Diff parameters (old_file_path, new_file_path, new_file_contents, tab_name)
---@param resolution_callback function Callback to call when diff resolves
---@param config table Plugin configuration
function M.setup_inline_diff(params, resolution_callback, config)
  local diff = require("claudecode.diff")

  local autocmd_ids = {}
  local buf = nil
  local partial_setup = {
    new_buffer = nil,
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
  local old_file_exists = vim.fn.filereadable(params.old_file_path) == 1
  local is_new_file = not old_file_exists

  if old_file_exists then
    local is_dirty = diff._is_buffer_dirty(params.old_file_path)
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

  -- Tear down any prior diff using this buffer
  for name, d in pairs(diff._get_active_diffs()) do
    if d.layout == "unified" and d.new_buffer == buf then
      diff._cleanup_diff_state(name, "replaced by new diff")
    end
  end

  -- Render (streaming or static) - no window opened
  if config and config.diff_opts and config.diff_opts.stream_reveal then
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    render_diff_buffer_streamed(buf, lines, line_types, {
      delay_ms = config.diff_opts.stream_reveal_delay_ms or 0,
      chars_per_tick = config.diff_opts.stream_reveal_chars_per_tick or 1,
    })
  else
    M.render_diff_buffer(buf, lines, line_types)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
  end
  partial_setup.new_buffer = buf

  vim.b[buf].claudecode_diff_tab_name = tab_name
  vim.b[buf].claudecode_inline_diff = true

  local ft = diff._detect_filetype(params.new_file_path)
  if ft and ft ~= "" then
    vim.api.nvim_set_option_value("filetype", ft, { buf = buf })
  end

  -- Register state (window opened later via open_inline_diff or autocmd)
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
    for _, ev in ipairs({ "BufDelete", "BufUnload", "BufWipeout" }) do
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
      new_buffer = buf,
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
end

-- ── User commands ────────────────────────────────────────────────

---Open ClaudeCodeBuffer in the current tab. Creates a vsplit if not already shown.
---@param tab_name string|nil Optional tab_name to link the window to
function M.open_inline_diff(tab_name)
  local buf = vim.fn.bufnr(CLAUDE_BUFFER_NAME)
  if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
    vim.notify("ClaudeCode: no diff buffer ready", vim.log.levels.INFO)
    return
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      return
    end
  end

  vim.cmd("rightbelow vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  pcall(vim.api.nvim_set_option_value, "signcolumn", "yes", { win = win })
  vim.cmd("wincmd =")

  if tab_name then
    local diff = require("claudecode.diff")
    local diff_data = diff._get_active_diffs()[tab_name]
    if diff_data and vim.api.nvim_win_is_valid(win) then
      diff_data.new_window = win
    end
  end
end

---Close ClaudeCodeBuffer window if visible in current tab.
function M.close_inline_diff()
  local buf = vim.fn.bufnr(CLAUDE_BUFFER_NAME)
  if buf == -1 then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_close, win, false)
      return
    end
  end
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
end

--- Resolve an inline diff as rejected.
---@param tab_name string The diff identifier
---@param diff_data table The diff state data
function M.resolve_inline_as_rejected(tab_name, diff_data)
  local result = {
    content = { { type = "text", text = "DIFF_REJECTED" }, { type = "text", text = tab_name } },
  }
  diff_data.status = "rejected"
  diff_data.result_content = result
  if diff_data.resolution_callback then
    diff_data.resolution_callback(result)
  end
end

--- Clean up an inline diff's state and UI.
---@param tab_name string The diff identifier
---@param diff_data table The diff state data
function M.cleanup_inline_diff(tab_name, diff_data)
  local diff = require("claudecode.diff")

  reveal_gen = reveal_gen + 1 -- Stop streaming animation

  for _, autocmd_id in ipairs(diff_data.autocmd_ids or {}) do
    pcall(vim.api.nvim_del_autocmd, autocmd_id)
  end

  -- Close any window(s) showing the buffer
  if diff_data.new_buffer and vim.api.nvim_buf_is_valid(diff_data.new_buffer) then
    for _, win in ipairs(vim.fn.win_findbuf(diff_data.new_buffer)) do
      pcall(vim.api.nvim_win_close, win, false)
    end
  end

  -- Keep the ClaudeCodeBuffer open: load the reviewed file content after diff
  if diff_data.new_buffer and vim.api.nvim_buf_is_valid(diff_data.new_buffer) then
    pcall(function()
      local b = diff_data.new_buffer
      vim.api.nvim_buf_set_option(b, "modifiable", true)
      vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
      local content_lines = {}
      local f = io.open(diff_data.old_file_path, "r")
      if f then
        local text = f:read("*a") or ""
        f:close()
        content_lines = vim.split(text, "\n", { plain = true })
        if #content_lines > 0 and content_lines[#content_lines] == "" then
          table.remove(content_lines)
        end
      end
      vim.api.nvim_buf_set_lines(b, 0, -1, false, content_lines)
      vim.api.nvim_buf_set_option(b, "buftype", "nofile")
      vim.api.nvim_buf_set_option(b, "bufhidden", "hide")
      vim.api.nvim_buf_set_option(b, "modifiable", false)
      vim.b[b].claudecode_inline_diff = nil
      vim.b[b].claudecode_diff_tab_name = nil
      local ft = diff._detect_filetype(diff_data.old_file_path)
      if ft and ft ~= "" then
        vim.api.nvim_set_option_value("filetype", ft, { buf = b })
      end
    end)
  end

  logger.debug("diff", "Cleaned up inline diff for", tab_name)
end

return M
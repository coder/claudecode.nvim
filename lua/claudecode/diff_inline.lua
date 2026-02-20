--- Inline diff module for Claude Code Neovim integration.
-- Provides a VS Code-style unified inline diff view with deleted (red/strikethrough)
-- and added (green) lines interleaved in a single read-only buffer.
local M = {}

local logger = require("claudecode.logger")

local ns = vim.api.nvim_create_namespace("claudecode_inline_diff")

-- ── Highlight groups ──────────────────────────────────────────────

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
--- Returns parallel arrays: lines[] (buffer content) and line_types[] ("unchanged"|"added"|"deleted").
---@param old_text string Original file content
---@param new_text string Proposed file content
---@return string[] lines Buffer lines for display
---@return string[] line_types Parallel array of "unchanged"|"added"|"deleted"
function M.compute_inline_diff(old_text, new_text)
  old_text = old_text or ""
  new_text = new_text or ""

  local hunks = vim.diff(old_text, new_text, { result_type = "indices" }) or {}

  local old_lines = split_lines(old_text)
  local new_lines = split_lines(new_text)

  local result_lines = {}
  local result_types = {}
  local old_pos = 1
  local new_pos = 1

  for _, hunk in ipairs(hunks) do
    local start_a, count_a, _, count_b = hunk[1], hunk[2], hunk[3], hunk[4]

    -- Unchanged lines before this hunk
    local unchanged_count
    if count_a > 0 then
      unchanged_count = start_a - old_pos
    else
      -- Pure insertion: start_a is the last unchanged line before the insertion
      unchanged_count = start_a - old_pos + 1
    end

    for _ = 1, unchanged_count do
      result_lines[#result_lines + 1] = new_lines[new_pos]
      result_types[#result_types + 1] = "unchanged"
      old_pos = old_pos + 1
      new_pos = new_pos + 1
    end

    -- Deleted lines from old
    for _ = 1, count_a do
      result_lines[#result_lines + 1] = old_lines[old_pos]
      result_types[#result_types + 1] = "deleted"
      old_pos = old_pos + 1
    end

    -- Added lines from new
    for _ = 1, count_b do
      result_lines[#result_lines + 1] = new_lines[new_pos]
      result_types[#result_types + 1] = "added"
      new_pos = new_pos + 1
    end
  end

  -- Remaining unchanged lines after the last hunk
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

--- Apply line highlights and sign-column markers via extmarks.
---@param buf number Buffer handle
---@param lines string[] Lines to set
---@param line_types string[] Parallel type array
function M.render_diff_buffer(buf, lines, line_types)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  for i, lt in ipairs(line_types) do
    if lt == "added" then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        line_hl_group = "ClaudeCodeInlineDiffAdd",
        sign_text = "+",
        sign_hl_group = "ClaudeCodeInlineDiffAddSign",
      })
    elseif lt == "deleted" then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        line_hl_group = "ClaudeCodeInlineDiffDelete",
        sign_text = "-",
        sign_hl_group = "ClaudeCodeInlineDiffDeleteSign",
      })
    end
  end
end

-- ── Setup ─────────────────────────────────────────────────────────

--- Set up an inline diff view for the given parameters.
---@param params table Diff parameters (old_file_path, new_file_path, new_file_contents, tab_name)
---@param resolution_callback function Callback to call when diff resolves
---@param config table Plugin configuration
function M.setup_inline_diff(params, resolution_callback, config)
  local diff = require("claudecode.diff")

  -- Version check: vim.diff requires Neovim >= 0.9.0
  if not vim.diff then
    error({
      code = -32000,
      message = "Inline diff requires Neovim >= 0.9.0",
      data = "vim.diff() is not available. Please use layout = 'vertical' or 'horizontal', or upgrade Neovim.",
    })
  end

  setup_highlights()

  local tab_name = params.tab_name
  local old_file_exists = vim.fn.filereadable(params.old_file_path) == 1
  local is_new_file = not old_file_exists

  -- Dirty buffer check
  if old_file_exists then
    local is_dirty = diff._is_buffer_dirty(params.old_file_path)
    if is_dirty then
      error({
        code = -32000,
        message = "Cannot create diff: file has unsaved changes",
        data = "Please save (:w) or discard (:e!) changes to " .. params.old_file_path .. " before creating diff",
      })
    end
  end

  -- Read old file content
  local old_text = ""
  if not is_new_file then
    local f = io.open(params.old_file_path, "r")
    if f then
      old_text = f:read("*a") or ""
      f:close()
    end
  end

  -- Compute diff
  local lines, line_types = M.compute_inline_diff(old_text, params.new_file_contents)

  -- Create scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  if buf == 0 then
    error({ code = -32000, message = "Buffer creation failed", data = "Could not create inline diff buffer" })
  end

  pcall(vim.api.nvim_buf_set_name, buf, tab_name .. " (inline diff)")
  vim.api.nvim_buf_set_option(buf, "buftype", "acwrite")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  -- Render content + highlights
  M.render_diff_buffer(buf, lines, line_types)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  -- Buffer metadata
  vim.b[buf].claudecode_diff_tab_name = tab_name
  vim.b[buf].claudecode_inline_diff = true

  -- Syntax highlighting via filetype
  local ft = diff._detect_filetype(params.new_file_path)
  if ft and ft ~= "" then
    vim.api.nvim_set_option_value("filetype", ft, { buf = buf })
  end

  -- Handle new-tab mode
  local original_tab_number = vim.api.nvim_get_current_tabpage()
  local created_new_tab = false
  local terminal_win_in_new_tab = nil
  local new_tab_handle = nil
  local had_terminal_in_original = false

  if config and config.diff_opts and config.diff_opts.open_in_new_tab then
    original_tab_number, terminal_win_in_new_tab, had_terminal_in_original, new_tab_handle =
      diff._display_terminal_in_new_tab()
    created_new_tab = true
  end

  -- Save terminal window width so we can restore it after the diff closes
  local term_win = diff._find_claudecode_terminal_window()
  local term_width = nil
  if term_win and vim.api.nvim_win_is_valid(term_win) then
    term_width = vim.api.nvim_win_get_width(term_win)
  end

  -- Open a vsplit for the inline diff buffer
  -- When in a new tab, use a window from the current tab rather than the global
  -- search which could return a window from the original tab
  local editor_win
  if created_new_tab then
    local tab_wins = vim.api.nvim_tabpage_list_wins(0)
    for _, w in ipairs(tab_wins) do
      if w ~= terminal_win_in_new_tab then
        editor_win = w
        break
      end
    end
    -- Fallback to first window in the new tab
    if not editor_win and #tab_wins > 0 then
      editor_win = tab_wins[1]
    end
  else
    editor_win = diff._find_main_editor_window()
  end
  if editor_win then
    vim.api.nvim_set_current_win(editor_win)
  end
  vim.cmd("rightbelow vsplit")
  local diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(diff_win, buf)

  -- Configure window for sign column display
  pcall(vim.api.nvim_set_option_value, "signcolumn", "yes", { win = diff_win })

  -- Equalize window widths
  vim.cmd("wincmd =")

  -- Scroll to first change
  for i, lt in ipairs(line_types) do
    if lt ~= "unchanged" then
      pcall(vim.api.nvim_win_set_cursor, diff_win, { i, 0 })
      break
    end
  end

  -- Handle terminal focus
  if config and config.diff_opts and config.diff_opts.keep_terminal_focus then
    vim.schedule(function()
      if terminal_win_in_new_tab and vim.api.nvim_win_is_valid(terminal_win_in_new_tab) then
        vim.api.nvim_set_current_win(terminal_win_in_new_tab)
        vim.cmd("startinsert")
        return
      end

      local terminal_win = diff._find_claudecode_terminal_window()
      if terminal_win then
        vim.api.nvim_set_current_win(terminal_win)
        vim.cmd("startinsert")
      end
    end)
  end

  -- Restore terminal width after opening the split
  if terminal_win_in_new_tab and vim.api.nvim_win_is_valid(terminal_win_in_new_tab) then
    local terminal_config = config.terminal or {}
    local split_width = terminal_config.split_width_percentage or 0.30
    local total_width = vim.o.columns
    local terminal_width = math.floor(total_width * split_width)
    vim.api.nvim_win_set_width(terminal_win_in_new_tab, terminal_width)
  elseif term_win and vim.api.nvim_win_is_valid(term_win) then
    local win_config = vim.api.nvim_win_get_config(term_win)
    local is_floating = win_config.relative and win_config.relative ~= ""
    if not is_floating and term_width then
      pcall(vim.api.nvim_win_set_width, term_win, term_width)
    end
  end

  -- Register autocmds
  local aug = diff._get_autocmd_group()
  local autocmd_ids = {}

  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = aug,
    buffer = buf,
    callback = function()
      diff._resolve_diff_as_saved(tab_name, buf)
      return true -- prevent actual write
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

  -- Register state with layout = "inline"
  diff._register_diff_state(tab_name, {
    old_file_path = params.old_file_path,
    new_file_path = params.new_file_path,
    new_file_contents = params.new_file_contents,
    new_buffer = buf,
    new_window = diff_win,
    lines = lines,
    line_types = line_types,
    is_new_file = is_new_file,
    autocmd_ids = autocmd_ids,
    created_at = vim.fn.localtime(),
    status = "pending",
    resolution_callback = resolution_callback,
    result_content = nil,
    layout = "inline",
    -- Tab/window tracking
    original_tab_number = original_tab_number,
    created_new_tab = created_new_tab,
    new_tab_number = new_tab_handle,
    had_terminal_in_original = had_terminal_in_original,
    terminal_win_in_new_tab = terminal_win_in_new_tab,
    term_win = term_win,
    term_width = term_width,
  })
end

-- ── Resolution functions ──────────────────────────────────────────

--- Resolve an inline diff as saved (user accepted changes).
---@param tab_name string The diff identifier
---@param diff_data table The diff state data
function M.resolve_inline_as_saved(tab_name, diff_data)
  logger.debug("diff", "Accepting inline diff for", tab_name)

  local content = M.extract_new_content(diff_data.lines, diff_data.line_types)
  -- Preserve trailing newline when original new_file_contents had one
  if diff_data.new_file_contents:sub(-1) == "\n" and content:sub(-1) ~= "\n" then
    content = content .. "\n"
  end

  local result = {
    content = {
      { type = "text", text = "FILE_SAVED" },
      { type = "text", text = content },
    },
  }

  diff_data.status = "saved"
  diff_data.result_content = result

  if diff_data.resolution_callback then
    diff_data.resolution_callback(result)
  else
    logger.debug("diff", "No resolution callback found for saved inline diff", tab_name)
  end

  logger.debug("diff", "Inline diff saved; awaiting close_tab for cleanup")
end

--- Resolve an inline diff as rejected (user closed/rejected).
---@param tab_name string The diff identifier
---@param diff_data table The diff state data
function M.resolve_inline_as_rejected(tab_name, diff_data)
  local result = {
    content = {
      { type = "text", text = "DIFF_REJECTED" },
      { type = "text", text = tab_name },
    },
  }

  diff_data.status = "rejected"
  diff_data.result_content = result

  if diff_data.resolution_callback then
    diff_data.resolution_callback(result)
  end
end

-- ── Cleanup ───────────────────────────────────────────────────────

--- Clean up an inline diff's state and UI.
---@param tab_name string The diff identifier
---@param diff_data table The diff state data
function M.cleanup_inline_diff(tab_name, diff_data)
  local diff = require("claudecode.diff")

  -- Clean up autocmds
  for _, autocmd_id in ipairs(diff_data.autocmd_ids or {}) do
    pcall(vim.api.nvim_del_autocmd, autocmd_id)
  end

  -- Handle new-tab cleanup
  if diff_data.created_new_tab then
    if diff_data.original_tab_number and vim.api.nvim_tabpage_is_valid(diff_data.original_tab_number) then
      pcall(vim.api.nvim_set_current_tabpage, diff_data.original_tab_number)
    end

    if diff_data.new_tab_number and vim.api.nvim_tabpage_is_valid(diff_data.new_tab_number) then
      pcall(vim.api.nvim_set_current_tabpage, diff_data.new_tab_number)
      pcall(vim.cmd, "tabclose")
      if diff_data.original_tab_number and vim.api.nvim_tabpage_is_valid(diff_data.original_tab_number) then
        pcall(vim.api.nvim_set_current_tabpage, diff_data.original_tab_number)
      end
    end

    -- Ensure terminal remains visible in the original tab
    local terminal_ok, terminal_module = pcall(require, "claudecode.terminal")
    if terminal_ok and diff_data.had_terminal_in_original then
      pcall(terminal_module.ensure_visible)
      local terminal_win = diff._find_claudecode_terminal_window()
      if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
        local win_config = vim.api.nvim_win_get_config(terminal_win)
        local is_floating = win_config.relative and win_config.relative ~= ""
        if not is_floating and diff_data.term_width then
          pcall(vim.api.nvim_win_set_width, terminal_win, diff_data.term_width)
        end
      end
    end
  else
    -- Close the diff split window
    if diff_data.new_window and vim.api.nvim_win_is_valid(diff_data.new_window) then
      pcall(vim.api.nvim_win_close, diff_data.new_window, true)
    end

    -- Restore terminal width
    if diff_data.term_win and vim.api.nvim_win_is_valid(diff_data.term_win) then
      local win_config = vim.api.nvim_win_get_config(diff_data.term_win)
      local is_floating = win_config.relative and win_config.relative ~= ""
      if not is_floating and diff_data.term_width then
        pcall(vim.api.nvim_win_set_width, diff_data.term_win, diff_data.term_width)
      end
    end
  end

  -- Buffer might already be wiped by bufhidden=wipe when its window closed
  if diff_data.new_buffer and vim.api.nvim_buf_is_valid(diff_data.new_buffer) then
    pcall(vim.api.nvim_buf_delete, diff_data.new_buffer, { force = true })
  end

  logger.debug("diff", "Cleaned up inline diff for", tab_name)
end

return M

--- Tool implementation for opening a file.

local schema = {
  description = "Open a file in the editor and optionally select a range of text",
  inputSchema = {
    type = "object",
    properties = {
      filePath = {
        type = "string",
        description = "Path to the file to open",
      },
      preview = {
        type = "boolean",
        description = "Whether to open the file in preview mode",
        default = false,
      },
      startLine = {
        type = "integer",
        minimum = 1,
        description = "Optional: Line number to start selection",
      },
      endLine = {
        type = "integer",
        minimum = 1,
        description = "Optional: Line number to end selection",
      },
      startText = {
        type = "string",
        description = "Text pattern to find the start of the selection range. Selects from the beginning of this match.",
      },
      endText = {
        type = "string",
        description = "Text pattern to find the end of the selection range. Selects up to the end of this match. If not provided, only the startText match will be selected.",
      },
      selectToEndOfLine = {
        type = "boolean",
        description = "If true, selection will extend to the end of the line containing the endText match.",
        default = false,
      },
      makeFrontmost = {
        type = "boolean",
        description = "Whether to make the file the active editor tab. If false, the file will be opened in the background without changing focus.",
        default = true,
      },
    },
    required = { "filePath" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Finds a suitable main editor window to open files in.
---Excludes terminals, sidebars, and floating windows.
---@return integer? win_id Window ID of the main editor window, or nil if not found
local function find_main_editor_window()
  local windows = vim.api.nvim_list_wins()

  for _, win in ipairs(windows) do
    local buf = vim.api.nvim_win_get_buf(win)
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
    local filetype = vim.api.nvim_buf_get_option(buf, "filetype")
    local win_config = vim.api.nvim_win_get_config(win)

    -- Check if this is a suitable window
    local is_suitable = true

    -- Skip floating windows
    if win_config.relative and win_config.relative ~= "" then
      is_suitable = false
    end

    -- Skip special buffer types
    if is_suitable and (buftype == "terminal" or buftype == "nofile" or buftype == "prompt") then
      is_suitable = false
    end

    -- Skip windows that are part of a diff (vimdiff, diffview.nvim, fugitive, or
    -- claudecode's own diff): :edit-ing into one clears its window-local 'diff'
    -- and destroys the user's diff layout (issue #277).
    if is_suitable and vim.api.nvim_win_get_option(win, "diff") then
      is_suitable = false
    end

    -- Skip the preview window: it is small, keeps its height, and the next :pedit replaces the file in it.
    if is_suitable and vim.api.nvim_win_get_option(win, "previewwindow") then
      is_suitable = false
    end

    -- Skip known sidebar filetypes
    if
      is_suitable
      and (
        filetype == "neo-tree"
        or filetype == "neo-tree-popup"
        or filetype == "NvimTree"
        or filetype == "oil"
        or filetype == "minifiles"
        or filetype == "netrw"
        or filetype == "aerial"
        or filetype == "tagbar"
      )
    then
      is_suitable = false
    end

    -- This looks like a main editor window
    if is_suitable then
      return win
    end
  end

  return nil
end

---Returns the preview window in the tab page of `win`, or nil.
---@param win integer
---@return integer? win_id
local function preview_window_in_tab(win)
  for _, tab_win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
    if vim.api.nvim_win_get_option(tab_win, "previewwindow") then
      return tab_win
    end
  end
  return nil
end

---Returns the loaded buffer that `:edit` would show for `file_path`, or nil. bufexists() and bufadd() find it the way
---`:edit` does, by name or by the inode Neovim cached for it, so a symlink, a symlinked directory, or a hard link
---finds it. bufexists() comes first because bufadd() creates a buffer when none exists.
---@param file_path string
---@return integer? bufnr
local function loaded_buffer(file_path)
  if vim.fn.bufexists(file_path) == 1 then
    local buf = vim.fn.bufadd(file_path)
    if vim.api.nvim_buf_is_loaded(buf) then
      return buf
    end
  end
  return nil
end

-- Buffers whose file did not exist when Neovim read them, and that Neovim has not read or written since (BF_NEW in
-- Neovim). After the file is created, Neovim asks W13 about such a buffer when a window enters it or `:checktime` checks
-- it, and no FileChangedShell autocommand can answer W13. A buffer loaded before this module counts when its file is
-- missing.
local new_file_buffers = {}
do
  local group = vim.api.nvim_create_augroup("ClaudeCodeOpenFileNewFiles", { clear = true })
  vim.api.nvim_create_autocmd("BufNewFile", {
    group = group,
    callback = function(args)
      new_file_buffers[args.buf] = true
    end,
  })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufUnload" }, {
    group = group,
    callback = function(args)
      new_file_buffers[args.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      -- Writing another file (`:w {file}`) keeps BF_NEW. An earlier BufWritePost autocommand can wipe the buffer.
      if vim.api.nvim_buf_is_valid(args.buf) and args.match == vim.api.nvim_buf_get_name(args.buf) then
        new_file_buffers[args.buf] = nil
      end
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if
      name ~= ""
      and vim.api.nvim_buf_is_loaded(buf)
      and vim.api.nvim_buf_get_option(buf, "buftype") == ""
      and vim.fn.filereadable(name) == 0
    then
      new_file_buffers[buf] = true
    end
  end
end

---Runs the Ex command `command`, which can load the file of `buf` again. Run from Lua, an error in a user's
---autocommand stops that reload halfway: the buffer keeps its old text with empty lines added, but takes the file as
---read, so a later `:w` writes that text over the file without a warning. When `command` fails after the reload began,
---the buffer reads its file again under `:silent!`, which lets the read end as for a command the user types, and then
---the error is raised. Only then, because `:silent!` also hides errors from autocommands that check for them.
---@param buf integer
---@param command string
local function run_reload_command(buf, command)
  local reading = false
  local autocmd = vim.api.nvim_create_autocmd("BufReadPre", {
    buffer = buf,
    callback = function()
      reading = true
    end,
  })
  local ok, err = pcall(vim.cmd, command)
  pcall(vim.api.nvim_del_autocmd, autocmd)
  if not ok then
    if reading and vim.api.nvim_buf_is_loaded(buf) and not vim.api.nvim_buf_get_option(buf, "modified") then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent! edit")
      end)
    end
    error(err, 0)
  end
end

---Runs `fn`, which can enter `buf` or run `:checktime` for it, so that Neovim does not ask the user about a file that
---changed on disk. Neovim asks for a buffer with unsaved changes, and with 'noautoread' for any buffer, and the user's
---next key answers: `l` loads the file and drops the unsaved changes. A FileChangedShell autocommand replaces that
---question, so openFile adds one, after the user's, that loads a buffer without unsaved changes again and keeps one
---with unsaved changes as it is.
---@param buf integer? A buffer that is not loaded has no file to check
---@param fn fun()
local function without_file_changed_question(buf, fn)
  if not (buf and vim.api.nvim_buf_is_loaded(buf)) then
    return fn()
  end
  local autocmd = vim.api.nvim_create_autocmd("FileChangedShell", {
    buffer = buf,
    callback = function()
      vim.v.fcs_choice = vim.api.nvim_buf_get_option(buf, "modified") and "" or "reload"
    end,
  })
  local ok, err = pcall(fn)
  -- A user's `autocmd! FileChangedShell` can delete it first.
  pcall(vim.api.nvim_del_autocmd, autocmd)
  if not ok then
    error(err, 0)
  end
end

---Returns whether the event list `events`, a value of 'eventignore' or 'eventignorewin', ignores FileChangedShell.
---Neovim 0.12 takes "all,-FileChangedShell".
---@param events string
---@return boolean
local function ignores_file_changed_shell(events)
  local ignored = false
  for item in events:lower():gmatch("[^,]+") do
    if item == "-filechangedshell" then
      return false
    end
    ignored = ignored or item == "all" or item == "filechangedshell"
  end
  return ignored
end

---Returns whether Neovim skips FileChangedShell autocommands when openFile runs `:checktime` for `buf`. Like Neovim,
---'eventignorewin' (Neovim 0.11 and later) counts for the current window when it shows `buf`, and otherwise only
---when every window that shows `buf` ignores the event.
---@param buf integer A buffer that a window shows
---@return boolean
local function file_changed_shell_ignored(buf)
  if ignores_file_changed_shell(vim.o.eventignore) then
    return true
  end
  if vim.fn.exists("+eventignorewin") == 0 then
    return false
  end
  local wins = buf == vim.api.nvim_get_current_buf() and { vim.api.nvim_get_current_win() } or vim.fn.win_findbuf(buf)
  for _, win in ipairs(wins) do
    if not ignores_file_changed_shell(vim.api.nvim_win_get_option(win, "eventignorewin")) then
      return false
    end
  end
  return #wins > 0
end

---Returns whether Neovim can skip FileChangedShell autocommands when it checks the file of `buf` as `win` enters it:
---'eventignore' ignores the event, or 'eventignorewin' of `win` or of a window that shows `buf` does.
---@param buf integer
---@param win integer
---@return boolean
local function file_changed_shell_can_be_ignored(buf, win)
  if ignores_file_changed_shell(vim.o.eventignore) then
    return true
  end
  if vim.fn.exists("+eventignorewin") == 0 then
    return false
  end
  local wins = vim.fn.win_findbuf(buf)
  wins[#wins + 1] = win
  for _, shown_in in ipairs(wins) do
    if ignores_file_changed_shell(vim.api.nvim_win_get_option(shown_in, "eventignorewin")) then
      return true
    end
  end
  return false
end

---Runs `fn` while Neovim does not check the file of `buf`: it checks only a buffer whose 'buftype' is empty. The
---BufEnter and BufWinEnter autocommands that `fn` triggers see 'buftype' "acwrite". Not "nowrite": Neovim reads
---'modified' as off for a nowrite buffer, so an autocommand that loads an unmodified buffer again would drop unsaved
---changes. They also see 'write' off: :write of an acwrite buffer skips the E13 and changed-file checks and runs
---BufWriteCmd, so a user's handler would write the buffer over the file. With 'write' off every write fails (E142).
---@param buf integer
---@param fn fun()
local function without_neovim_file_check(buf, fn)
  local function set_buftype(value)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("noautocmd setlocal buftype=" .. value)
    end)
  end
  set_buftype("acwrite")
  local write = vim.o.write
  vim.cmd("noautocmd set nowrite")
  local ok, err = pcall(fn)
  if write then
    vim.cmd("noautocmd set write")
  end
  if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, "buftype") == "acwrite" then
    set_buftype("")
  end
  if not ok then
    error(err, 0)
  end
end

---Loads `buf` again when its file changed on disk and it has no unsaved changes, as `:edit` does in a window that shows
---it. A buffer with unsaved changes keeps them, and a later `:w` still warns that the file changed. With 'autoread'
---Neovim loads the file without FileChangedShell. Without it, when 'eventignore' or 'eventignorewin' ignores the
---event, nothing is checked, because Neovim would ask the user. A buffer opened before its file existed reads the
---file with `:edit` in `win`, as W13's "Load File" would, except while the user holds Visual or Select mode in the
---middle of a command (`keep_mode`), which `:edit` ends, or when an autocommand made `win` show another buffer.
---@param buf integer
---@param win integer A window that shows `buf`, or will show it
---@param keep_mode boolean
local function check_file_on_disk(buf, win, keep_mode)
  -- Neovim checks the file only of a buffer whose 'buftype' is empty.
  if vim.api.nvim_buf_get_option(buf, "modified") or vim.api.nvim_buf_get_option(buf, "buftype") ~= "" then
    return
  end
  if new_file_buffers[buf] then
    -- `:edit` re-reads the buffer of `win`, and it empties a 'nofile' buffer.
    if
      vim.api.nvim_win_get_buf(win) == buf
      and not (keep_mode and vim.api.nvim_get_mode().mode:match("^[vVsS\22\19]"))
    then
      vim.api.nvim_win_call(win, function()
        run_reload_command(buf, "edit")
      end)
    end
    return
  end
  if vim.fn.getbufvar(buf, "&autoread") == 0 and file_changed_shell_ignored(buf) then
    return
  end
  without_file_changed_question(buf, function()
    run_reload_command(buf, "checktime " .. buf)
  end)
end

---Runs `fn`, which shows `buf` in `win`, a window that does not show it yet, so that Neovim does not ask the user about
---the file of a loaded `buf`, and loads a changed file again as check_file_on_disk() does. When Neovim's own check as
---`win` enters `buf` cannot ask, check_file_on_disk() runs first, so that no reload runs inside the enter, where a
---failing autocommand would stop it. Otherwise that check is turned off and check_file_on_disk() runs after: W13 runs
---no FileChangedShell, and Neovim can skip one.
---@param buf integer?
---@param win integer
---@param keep_mode boolean
---@param fn fun()
local function show_buffer(buf, win, keep_mode, fn)
  if not (buf and vim.api.nvim_buf_is_loaded(buf)) or vim.api.nvim_buf_get_option(buf, "buftype") ~= "" then
    return fn()
  end
  if new_file_buffers[buf] or file_changed_shell_can_be_ignored(buf, win) then
    without_neovim_file_check(buf, fn)
    -- An autocommand can close `win` as it gets the buffer. The caller reports that.
    if vim.api.nvim_win_is_valid(win) then
      check_file_on_disk(buf, win, keep_mode)
    end
  else
    -- An error of a user's autocommand in the check comes after the buffer is shown.
    local ok, err = pcall(check_file_on_disk, buf, win, keep_mode)
    -- A buffer with unsaved changes was not checked.
    without_file_changed_question(buf, fn)
    if not ok then
      error(err, 0)
    end
  end
end

---Shows `file_path` from `win`, like `:edit`, or like `:pedit` when `preview` is set, and returns the window that
---shows it. A window that already shows the loaded buffer keeps it, and only a changed file on disk is loaded again,
---because `:edit` and `:pedit` re-read the buffer there: that fails on unsaved changes (E37) and resets folds in every
---window on that buffer. The preview path does not run `:pedit` at all, because `:pedit` also ends the user's Visual
---mode.
---@param win integer
---@param file_path string
---@param preview boolean
---@param keep_mode boolean The user is in the middle of a command
---@return integer win_id
local function open_from(win, file_path, preview, keep_mode)
  if not preview then
    local buf = loaded_buffer(file_path)
    if buf and vim.api.nvim_win_get_buf(win) == buf then
      check_file_on_disk(buf, win, keep_mode)
    else
      show_buffer(buf, win, keep_mode, function()
        vim.api.nvim_win_call(win, function()
          vim.cmd("edit " .. vim.fn.fnameescape(file_path))
        end)
      end)
    end
    return win
  end
  -- nvim_win_set_buf() loads the buffer in the preview window, so BufReadPost, FileType and BufEnter run once, there.
  local buf = vim.fn.bufadd(file_path)
  vim.api.nvim_buf_set_option(buf, "buflisted", true)
  local preview_win = preview_window_in_tab(win)
    or vim.api.nvim_win_call(win, function()
      -- The window :pedit makes (prepare_tagpreview() in Neovim).
      vim.cmd(vim.o.previewheight .. "split")
      local new_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_option(new_win, "previewwindow", true)
      vim.api.nvim_win_set_option(new_win, "winfixheight", true)
      vim.api.nvim_win_set_option(new_win, "scrollbind", false)
      vim.api.nvim_win_set_option(new_win, "cursorbind", false)
      vim.api.nvim_win_set_option(new_win, "diff", false)
      vim.api.nvim_win_set_option(new_win, "foldcolumn", "0")
      return new_win
    end)
  local shown = vim.api.nvim_win_get_buf(preview_win) == buf
  -- :pedit shows the file even when the preview window has 'winfixbuf' set, and keeps the option.
  local fixed = vim.fn.exists("+winfixbuf") == 1 and vim.api.nvim_win_get_option(preview_win, "winfixbuf")
  if fixed then
    vim.api.nvim_win_set_option(preview_win, "winfixbuf", false)
  end
  local ok, err = true, nil
  if not shown then
    ok, err = pcall(show_buffer, buf, preview_win, keep_mode, function()
      vim.api.nvim_win_set_buf(preview_win, buf)
    end)
  end
  if fixed and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_win_set_option(preview_win, "winfixbuf", true)
  end
  if not ok then
    error(err, 0)
  end
  -- An autocommand can clear 'previewwindow' or close the window as it gets the buffer.
  if not vim.api.nvim_win_is_valid(preview_win) or not vim.api.nvim_win_get_option(preview_win, "previewwindow") then
    error({ code = -32000, message = "File operation error", data = "No preview window shows the file" })
  end
  if shown then
    check_file_on_disk(buf, preview_win, keep_mode)
  end
  return preview_win
end

---Ends Visual or Select mode, if one is on. Select mode replaces the selected text with typed keys, so this runs
---before openFile sends `:normal!` keys.
local function leave_visual_or_select_mode()
  if vim.api.nvim_get_mode().mode:match("^[vVsS\22\19]") then
    vim.cmd("normal! \27")
  end
end

---Selects from `start_col` on `start_row` through `last_col` on `end_row` in charwise visual mode, both ends included.
---With 'selection' set to "exclusive", gv leaves out the character under `'>`, so `'>` goes one byte past
---`last_col`. The marks use setpos() because nvim_buf_set_mark on Neovim 0.8 also sets the mark's coladd,
---and gv then selects one more character. gv reselects in the buffer's last Visual mode, so a charwise Visual
---pass (v<Esc>) comes first, or a buffer last selected with V or CTRL-V gets a linewise or blockwise selection.
---It runs under :noautocmd, so its own ModeChanged pair does not reach user handlers or the selection tracker.
---gv must be the last key openFile sends: with 'selectmode' set to "cmd" it starts Select mode, where any later
---key would replace the selection.
---@param start_row integer 1-based row of the first character
---@param start_col integer 0-based byte column of the first character
---@param end_row integer 1-based row of the last character
---@param last_col integer 0-based byte column of the last byte to select
local function select_range(start_row, start_col, end_row, last_col)
  local end_col = last_col
  if vim.o.selection == "exclusive" then
    end_col = last_col + 1
  end
  leave_visual_or_select_mode()
  vim.cmd("noautocmd normal! v\27")
  vim.fn.setpos("'<", { 0, start_row, start_col + 1, 0 })
  vim.fn.setpos("'>", { 0, end_row, end_col + 1, 0 })
  vim.cmd("normal! gv")
end

---Returns how many lines `file_path` can show once opened, counting at most `max` lines of the file on disk.
---A loaded buffer for the file can hold unsaved lines, and openFile shows that buffer, so its count wins. A loaded
---buffer without unsaved changes gets the file again when it changed on disk, so then the larger count wins, and the
---selection is clamped if the buffer openFile shows ends up shorter.
---@param file_path string Path of the file to open
---@param max integer Lines to read from disk at most
---@return integer count
local function line_count_before_open(file_path, max)
  local buf = loaded_buffer(file_path)
  local count = buf and vim.api.nvim_buf_line_count(buf) or 0
  if count < max and not (buf and vim.api.nvim_buf_get_option(buf, "modified")) then
    -- readfile() returns no lines for an empty file, which opens as one empty line.
    count = math.max(count, #vim.fn.readfile(file_path, "", max), 1)
  end
  return count
end

--- Handles the openFile tool invocation.
--- Opens a file in the editor with optional selection.
---@param params table The input parameters for the tool
---@return table MCP-compliant response with content array
local function handler(params)
  if not params.filePath then
    error({ code = -32602, message = "Invalid params", data = "Missing filePath parameter" })
  end

  if vim.fn.getcmdwintype() ~= "" then
    error({ code = -32000, message = "File operation error", data = "The command-line window is open" })
  end
  -- The user is in the middle of a command: an operator (d, c, y, ...) waits for its motion, or Insert mode, Replace
  -- mode, CTRL-O from them, or the command line is on. The user's next keys finish that command in the current
  -- window, from where it started, so openFile must not change that window, its cursor or the mode. No key can
  -- cancel the command reliably, because a key reader in an autocommand can take the key first.
  local mode = vim.api.nvim_get_mode().mode
  -- Visual or Select mode that CTRL-O started from Insert or Replace mode goes back there after one command. Only
  -- state() tells it from plain Visual mode, with "S", and only on Neovim 0.10 and later.
  local ctrl_o_visual = mode:match("^[vVsS\22\19]") ~= nil
    and vim.fn.exists("*state") == 1
    and vim.fn.state():find("S", 1, true) ~= nil
  local mid_command = mode:match("^n[oi]") ~= nil or mode:match("^[iRc]") ~= nil or ctrl_o_visual

  local start_line, end_line
  if params.startLine ~= nil or params.endLine ~= nil then
    start_line = params.startLine == nil and 1 or params.startLine
    end_line = params.endLine == nil and start_line or params.endLine
    local valid = type(start_line) == "number"
      and type(end_line) == "number"
      and start_line % 1 == 0
      and end_line % 1 == 0
      and start_line >= 1
      and end_line >= start_line
    if not valid then
      error({
        code = -32602,
        message = "Invalid params",
        data = "startLine and endLine must be integers with 1 <= startLine <= endLine",
      })
    end
  end

  -- Expand a leading `~` only. `vim.fn.expand` would treat `$name` as an
  -- environment variable and strip undefined ones, breaking literal `$` paths
  -- (e.g. TanStack Router `$param` files like `src/routes/$post.tsx`).
  local file_path = require("claudecode.utils").expand_tilde(params.filePath)

  if vim.fn.filereadable(file_path) == 0 then
    -- Using a generic error code for tool-specific operational errors
    error({ code = -32000, message = "File operation error", data = "File not found: " .. file_path })
  end

  if start_line then
    local file_line_count = line_count_before_open(file_path, start_line)
    if start_line > file_line_count then
      error({
        code = -32602,
        message = "Invalid params",
        data = "startLine " .. start_line .. " is past the end of the file (" .. file_line_count .. " lines)",
      })
    end
  end

  -- Set default values for optional parameters
  local preview = params.preview or false
  local make_frontmost = params.makeFrontmost ~= false -- default true
  local select_to_end_of_line = params.selectToEndOfLine or false
  local start_text = type(params.startText) == "string" and params.startText ~= "" and params.startText or nil
  local end_text = type(params.endText) == "string" and params.endText ~= "" and params.endText or nil

  local message = "Opened file: " .. file_path

  local target_win
  if mid_command then
    -- The preview window takes the file, so the current window keeps its buffer and cursor, unless it is the
    -- preview window.
    if vim.api.nvim_win_get_option(0, "previewwindow") then
      error({
        code = -32000,
        message = "File operation error",
        data = "The user is in the middle of a command in the preview window",
      })
    end
    preview, target_win = true, vim.api.nvim_get_current_win()
  else
    target_win = find_main_editor_window()
  end

  if target_win then
    target_win = open_from(target_win, file_path, preview, mid_command)
  else
    -- Fallback: Create a new window if no suitable window found
    -- Try to move to a better position
    local origin_win = vim.api.nvim_get_current_win()
    vim.cmd("wincmd t") -- Go to top-left
    vim.cmd("wincmd l") -- Move right (to middle if layout is left|middle|right)
    if vim.api.nvim_win_get_option(0, "previewwindow") then
      -- A split of the preview window gets its 'previewheight' lines, so split the window below it.
      vim.cmd("wincmd j")
    end

    -- If we're still in a special window (a diff window — issue #277 — or the preview window), create
    -- a new split so we don't :edit over a terminal, sidebar, someone's diff, or the preview window.
    local cur_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(cur_win)
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")

    -- A preview goes to the preview window, which open_from() splits from this window when the tab page has none,
    -- so this window keeps its buffer and needs no split.
    if
      not preview
      and (
        buftype == "terminal"
        or buftype == "nofile"
        or vim.api.nvim_win_get_option(cur_win, "diff")
        or vim.api.nvim_win_get_option(cur_win, "previewwindow")
      )
    then
      vim.cmd("vsplit")
      -- The new split inherits window-local options (including 'diff') from the
      -- window we split off. Clear diff on it so the file we open never joins the
      -- user's diff set -- e.g. opening a file that is itself one of the diffed
      -- buffers would otherwise leave it diffing as an extra pane (issue #277).
      -- :diffoff acts on the current (new) window only, never :diffoff!.
      vim.cmd("diffoff")
    end

    target_win = open_from(vim.api.nvim_get_current_win(), file_path, preview, mid_command)
    if not make_frontmost then
      vim.api.nvim_set_current_win(origin_win)
    end
  end

  if make_frontmost and not mid_command then
    vim.api.nvim_set_current_win(target_win)
  end

  local function run_in_target_window(callback)
    if target_win then
      return vim.api.nvim_win_call(target_win, callback)
    end
    return callback()
  end

  -- Handle text selection by line numbers
  if start_line then
    run_in_target_window(function()
      -- endLine can run past the last line. start_line is clamped too, so a buffer that ends up shorter
      -- than the count checked before opening still gets a selection.
      end_line = math.min(end_line, vim.api.nvim_buf_line_count(0))
      start_line = math.min(start_line, end_line)
      -- With 'selection' inclusive, a charwise selection that ends on an empty line also covers that line's
      -- line break: gv selects the character under '>, and on an empty line that is the line break. Ending
      -- on the line above instead would move '> and the selection Claude receives off endLine.
      local end_line_text = vim.api.nvim_buf_get_lines(0, end_line - 1, end_line, false)[1]
      if mid_command then
        vim.api.nvim_win_set_cursor(0, { start_line, 0 })
        message = "Opened file and positioned at line " .. start_line
      else
        select_range(start_line, 0, end_line, math.max(#end_line_text - 1, 0))
        message = "Opened file and selected lines " .. start_line .. " to " .. end_line
      end
    end)
  end

  -- Handle text pattern selection
  if start_text then
    run_in_target_window(function()
      local buf = vim.api.nvim_get_current_buf()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local start_line_idx, start_col_idx
      local end_line_idx, end_col_idx

      -- Find start text
      for line_idx, line in ipairs(lines) do
        local col_idx = string.find(line, start_text, 1, true) -- plain text search
        if col_idx then
          start_line_idx = line_idx
          start_col_idx = col_idx - 1 -- Convert to 0-based
          break
        end
      end

      if start_line_idx then
        -- Find end text if provided
        if end_text then
          for line_idx = start_line_idx, #lines do
            local line = lines[line_idx] -- Access current line directly
            if line then
              local search_from = line_idx == start_line_idx and start_col_idx + string.len(start_text) + 1 or 1
              local col_idx = string.find(line, end_text, search_from, true)
              if col_idx then
                end_line_idx = line_idx
                end_col_idx = col_idx - 1 + string.len(end_text) - 1
                if select_to_end_of_line then
                  end_col_idx = math.max(string.len(line) - 1, 0)
                end
                break
              end
            end
          end

          if end_line_idx then
            message = 'Opened file and selected text from "' .. start_text .. '" to "' .. end_text .. '"'
          else
            message = 'Opened file and positioned at "' .. start_text .. '" (end text "' .. end_text .. '" not found)'
          end
        else
          -- Only start text provided
          end_line_idx = start_line_idx
          end_col_idx = start_col_idx + string.len(start_text) - 1
          message = 'Opened file and selected text "' .. start_text .. '"'
        end

        -- When endText is not found, only the cursor moves, as in the VS Code extension. In the middle of a command
        -- openFile sends no keys: the user's own Visual or Select mode can be on, and Select mode replaces the
        -- selection with any key.
        if mid_command then
          vim.api.nvim_win_set_cursor(0, { start_line_idx, start_col_idx })
          if end_line_idx then
            message = 'Opened file and positioned at "' .. start_text .. '"'
          end
        else
          -- A line range earlier in this call can leave Visual or Select mode on, and moving the cursor in it
          -- would stretch that selection.
          leave_visual_or_select_mode()
          vim.api.nvim_win_set_cursor(0, { start_line_idx, start_col_idx })
          vim.cmd("normal! zz") -- Center the match before gv, which must be the last key
          if end_line_idx then
            select_range(start_line_idx, start_col_idx, end_line_idx, end_col_idx)
          end
        end
      else
        message = 'Opened file, but text "' .. start_text .. '" not found'
      end
    end)
  end

  if mid_command then
    message = message
      .. " (shown in the preview window without a selection, because the user is in the middle of a command)"
  end

  -- Return format based on makeFrontmost parameter
  if make_frontmost then
    -- Simple message format when makeFrontmost=true
    return {
      content = {
        {
          type = "text",
          text = message,
        },
      },
    }
  else
    -- Detailed JSON format when makeFrontmost=false
    local buf = target_win and vim.api.nvim_win_get_buf(target_win) or vim.api.nvim_get_current_buf()
    local detailed_info = {
      success = true,
      filePath = file_path,
      languageId = vim.api.nvim_buf_get_option(buf, "filetype"),
      lineCount = vim.api.nvim_buf_line_count(buf),
    }

    return {
      content = {
        {
          type = "text",
          text = vim.json.encode(detailed_info),
        },
      },
    }
  end
end

return {
  name = "openFile",
  schema = schema,
  handler = handler,
}

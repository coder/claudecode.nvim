---Open file:line references from the Claude terminal with the mouse.
---Attached to the managed terminal buffer when `file_jump_keys` is set.
---@module 'claudecode.terminal.file_jump'

local M = {}

local PATH_CHAR = "[%w%._/%-:]"

---Parses a `path[:line]` token around a 1-based byte column of `text`.
---@param text string
---@param col integer
---@return string? file
---@return integer? line
function M.parse_token(text, col)
  if col < 1 or col > #text then
    return nil
  end
  local s, e = col, col
  while s > 1 and text:sub(s - 1, s - 1):match(PATH_CHAR) do
    s = s - 1
  end
  while e < #text and text:sub(e + 1, e + 1):match(PATH_CHAR) do
    e = e + 1
  end
  -- "path/to/file.ts:363-370" -> file "path/to/file.ts", line 363
  local file, line = text:sub(s, e):match("^([^:]+):?(%d*)")
  if not file or file == "" then
    return nil
  end
  return file, tonumber(line)
end

---Resolves the file reference under a click. Claude often splits a reference
---across two tokens on one line -- "apps/.../fileFixEval.ts (locate'd at
---fileFixEval.ts:848-852)" -- so a missing piece (the line number, or a path
---that actually resolves) is borrowed from any token sharing the basename.
---@param text string
---@param col integer
---@return string? file
---@return integer? line
function M.resolve(text, col)
  local file, line = M.parse_token(text, col)
  if not file then
    return nil
  end
  local base = vim.fs.basename(file)
  if not line then
    for f2, l2 in text:gmatch("([%w%._/%-]+):(%d+)") do
      if vim.fs.basename(f2) == base then
        line = tonumber(l2)
        break
      end
    end
  end
  if vim.fn.filereadable(file) == 0 then
    for f2 in text:gmatch("[%w%._/%-]+") do
      if f2 ~= file and vim.fs.basename(f2) == base and vim.fn.filereadable(f2) == 1 then
        file = f2
        break
      end
    end
    if vim.fn.filereadable(file) == 0 then
      file = M.find_by_basename(base)
    end
    if not file then
      return nil
    end
  end
  return file, line
end

---Finds a project file by basename for bare references like "fileFixEval.ts:97".
---Loaded buffers are checked first (covers untracked files), then the git
---index -- an existing, instant filename index that skips node_modules.
---@param base string
---@return string? file
function M.find_by_basename(base)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local n = vim.api.nvim_buf_get_name(b)
      if vim.fs.basename(n) == base and vim.fn.filereadable(n) == 1 then
        return n
      end
    end
  end
  local hits = vim.fn.systemlist({ "git", "ls-files", "--full-name", "--", base, "*/" .. base })
  if vim.v.shell_error == 0 and hits[1] and hits[1] ~= "" then
    -- ponytail: ambiguous basenames take git's first (lexical) hit; a picker
    -- would be the upgrade if that ever chooses wrong.
    return hits[1]
  end
  return nil
end

---Jumps to the file reference under the mouse. A floating terminal covers the
---editor, so it is hidden first (simple_toggle on a visible terminal, which
---routes through the provider's safe hide path -- #240/#183); a split terminal
---stays open and the previous window is used instead.
---@param bufnr integer The terminal buffer the mapping fired in
local function jump(bufnr)
  local mp = vim.fn.getmousepos()
  local text = (vim.api.nvim_buf_get_lines(bufnr, mp.line - 1, mp.line, false))[1] or ""
  local file, line = M.resolve(text, mp.column)
  if not file then
    return
  end
  local cfg = mp.winid ~= 0 and vim.api.nvim_win_is_valid(mp.winid) and vim.api.nvim_win_get_config(mp.winid)
  if cfg and cfg.relative ~= "" then
    require("claudecode.terminal").simple_toggle()
  else
    vim.cmd.wincmd("p")
  end
  vim.cmd.edit(vim.fn.fnameescape(file))
  if line then
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  end
end

---Attaches the buffer-local mouse mapping to a terminal buffer. Terminal mode
---is mapped too, so the click works while Claude's TUI has focus.
---@param bufnr integer
---@param keys string Left-hand side of the mapping, e.g. "<2-LeftMouse>"
function M.attach(bufnr, keys)
  vim.keymap.set({ "n", "t" }, keys, function()
    jump(bufnr)
  end, { buffer = bufnr, desc = "Claude Code: open file reference under mouse" })
end

return M

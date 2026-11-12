--- Working directory resolution helpers for ClaudeCode.nvim
---@module 'claudecode.cwd'

local M = {}

---Tell whether a path names an existing directory, as written: no expansion.
---@param path string
---@return boolean
local function is_directory(path)
  return vim.fn.isdirectory(path) == 1
end

---Normalize and validate a directory path
---@param dir string|nil
---@return string|nil
local function normalize_dir(dir)
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  -- A directory that exists is taken as written. `vim.fn.expand` reads `[`, `{`, `*`, `?`, `$` and `\` in a name as
  -- patterns or variables, so it would change the path of a folder that has them, or find none.
  if is_directory(dir) then
    return dir
  end
  -- Expand ~ and similar
  local expanded = vim.fn.expand(dir)
  if is_directory(expanded) then
    return expanded
  end
  return nil
end

---Find the git repository root starting from a directory
---@param start_dir string|nil
---@return string|nil
function M.git_root(start_dir)
  start_dir = normalize_dir(start_dir)
  if not start_dir then
    return nil
  end

  -- Prefer running without shell by passing a list
  local result
  if vim.fn.systemlist then
    local ok, _ = pcall(function()
      local _ = vim.fn.systemlist({ "git", "-C", start_dir, "rev-parse", "--show-toplevel" })
    end)
    if ok then
      result = vim.fn.systemlist({ "git", "-C", start_dir, "rev-parse", "--show-toplevel" })
    else
      -- Fallback to string command if needed
      local cmd = "git -C " .. vim.fn.shellescape(start_dir) .. " rev-parse --show-toplevel"
      result = vim.fn.systemlist(cmd)
    end
  end

  if vim.v.shell_error == 0 and result and #result > 0 then
    local root = normalize_dir(result[1])
    if root then
      return root
    end
  end

  -- Fallback: search for .git directory upward. The walk tests each folder as written. `vim.fn.finddir` reads its path
  -- as a list ('path' option syntax), so a space or a comma in the path split it, and a `;` ended it. It starts from the
  -- full path, so a relative `start_dir` also reaches the folders above the current one.
  local dir = vim.fn.fnamemodify(start_dir, ":p:h")
  while true do
    if vim.fn.isdirectory(dir .. "/.git") == 1 then
      return dir
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      return nil
    end
    dir = parent
  end
end

---Resolve the effective working directory based on terminal config and context
---@param term_cfg ClaudeCodeTerminalConfig
---@param ctx ClaudeCodeCwdContext
---@return string|nil
function M.resolve(term_cfg, ctx)
  if type(term_cfg) ~= "table" then
    return nil
  end

  -- 1) Custom provider takes precedence
  local provider = term_cfg.cwd_provider
  local provider_type = type(provider)
  if provider_type == "function" then
    local ok, res = pcall(provider, ctx)
    if ok then
      local p = normalize_dir(res)
      if p then
        return p
      end
    end
  end

  -- 2) Static cwd
  local static_cwd = normalize_dir(term_cfg.cwd)
  if static_cwd then
    return static_cwd
  end

  -- 3) Git repository root
  if term_cfg.git_repo_cwd then
    local start_dir = ctx and (ctx.file_dir or ctx.cwd) or vim.fn.getcwd()
    local root = M.git_root(start_dir)
    if root then
      return root
    end
  end

  -- 4) No override
  return nil
end

return M

--- A private folder for the files of one test block. Every test run on a host shares a fixed path under /tmp, so two
--- suites that run at once overwrite and delete each other's files there.
local M = {}

---@param path string
---@return string quoted path as one POSIX shell word
function M.quote(path)
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

---@return string dir The absolute path of a new empty folder that only this test run uses, under TMPDIR (default /tmp)
function M.new()
  -- The template names TMPDIR: without one, macOS's mktemp prefers its own per-user folder.
  local pipe = assert(io.popen('mktemp -d "${TMPDIR:-/tmp}/claudecode.XXXXXX"'))
  local dir = pipe:read("*l")
  pipe:close()
  assert(dir and dir ~= "", "mktemp -d failed")
  -- A relative TMPDIR gives a relative path.
  return require("pl.path").abspath(dir)
end

---@param dir string|nil A folder from M.new, or nil when M.new did not run
function M.remove(dir)
  if dir then
    os.execute("rm -rf -- " .. M.quote(dir))
  end
end

return M

--- A private folder for the files of one test block. Every test run on a host shares a fixed path under /tmp, so two
--- suites that run at once overwrite and delete each other's files there.
local M = {}

---@param path string
---@return string quoted path as one POSIX shell word
function M.quote(path)
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

---@return string dir A new empty folder that only this test run uses, under TMPDIR (default /tmp)
function M.new()
  local pipe = assert(io.popen("mktemp -d"))
  local dir = pipe:read("*l")
  pipe:close()
  assert(dir and dir:sub(1, 1) == "/", "mktemp -d gave " .. tostring(dir))
  return dir
end

---@param dir string|nil A folder from M.new, or nil when M.new did not run
function M.remove(dir)
  if dir then
    os.execute("rm -rf " .. M.quote(dir))
  end
end

return M

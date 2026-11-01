--- A private folder for the files of one test block. Every test run on a host shares a fixed path under /tmp, so two
--- suites that run at once overwrite and delete each other's files there.
local M = {}

---@return string dir A new empty folder that only this test run uses
function M.new()
  local pipe = assert(io.popen("mktemp -d"))
  local dir = pipe:read("*l")
  pipe:close()
  -- Checked, so the path needs no quoting in shell commands.
  assert(dir and dir:match("^/[%w/._-]+$"), "mktemp -d gave " .. tostring(dir))
  return dir
end

---@param dir string|nil A folder from M.new, or nil when M.new did not run
function M.remove(dir)
  if dir then
    assert(dir:match("^/[%w/._-]+$"), "not a folder from temp_dir.new: " .. dir)
    os.execute("rm -rf '" .. dir .. "'")
  end
end

return M

-- Busted takes one helper, so this one puts the stub tests/bin/claude first on PATH and then loads test_order.lua.
local ffi = require("ffi")
local abspath = require("pl.path").abspath

local helpers_dir = assert(abspath(debug.getinfo(1, "S").source:sub(2)):match("^(.*)/[^/]+$"))
local stub_dir = abspath(helpers_dir .. "/../bin")

ffi.cdef("int setenv(const char *name, const char *value, int overwrite);")

local path = os.getenv("PATH") or ""
if path:sub(1, #stub_dir + 1) ~= stub_dir .. ":" then
  assert(ffi.C.setenv("PATH", stub_dir .. (path ~= "" and ":" .. path or ""), 1) == 0, "setenv PATH failed")
end

return dofile(helpers_dir .. "/test_order.lua")

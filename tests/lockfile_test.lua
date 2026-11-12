-- Tests for lockfile module

local temp_dir = require("tests.helpers.temp_dir")
-- The home folder of the mock below: a private folder, so test runs that run at once keep their lock files apart.
local home

-- Load mock vim if needed
local real_vim = _G.vim
if not _G.vim then
  -- Create a basic vim mock
  _G.vim = { ---@type vim_global_api
    schedule_wrap = function(fn)
      return fn
    end,
    deepcopy = function(t) -- Basic deepcopy for testing
      local copy = {}
      for k, v in pairs(t) do
        if type(v) == "table" then
          copy[k] = _G.vim.deepcopy(v)
        else
          copy[k] = v
        end
      end
      return copy
    end,
    cmd = function() end, ---@type fun(command: string):nil
    api = {}, ---@type table
    fs = { remove = function() end }, ---@type vim_fs_module
    fn = { ---@type vim_fn_table
      expand = function(path)
        local expanded = path:gsub("~", function()
          return home
        end)
        return expanded
      end,
      -- Add other vim.fn mocks as needed by lockfile tests
      -- For now, only adding what's explicitly used or causing major type issues
      filereadable = function(path)
        -- Neovim gives 1 only for a file that exists, can be read and is not a folder (`:h filereadable()`), and it
        -- does not open the file. The shell's `test` says the same without opening it: opening a FIFO waits for a
        -- writer, and `io.open` on a folder gives a handle on Linux.
        local ok = os.execute("test -r " .. temp_dir.quote(path) .. " && ! test -d " .. temp_dir.quote(path))
        return (ok == 0 or ok == true) and 1 or 0
      end,
      fnamemodify = function(fname, _)
        return fname
      end,
      delete = function(_, _)
        return 0
      end,
      mode = function()
        return "n"
      end,
      buflisted = function(_)
        return 0
      end,
      bufname = function(_)
        return ""
      end,
      bufnr = function(_)
        return 0
      end,
      win_getid = function()
        return 0
      end,
      win_gotoid = function(_)
        return false
      end,
      line = function(_)
        return 0
      end,
      col = function(_)
        return 0
      end,
      virtcol = function(_)
        return 0
      end,
      getpos = function(_)
        return { 0, 0, 0, 0 }
      end,
      setpos = function(_, _)
        return false
      end,
      tempname = function()
        return ""
      end,
      globpath = function(_, _)
        return ""
      end,
      stdpath = function(_)
        return ""
      end,
      json_encode = function(_)
        return "{}"
      end,
      json_decode = function(_)
        return {}
      end,
      -- getcwd is defined later in setup, so no need to mock it here initially
      -- mkdir is defined later in setup
      -- getpid is defined later in setup
      getcwd = function()
        return "/mock/cwd"
      end,
      mkdir = function()
        return 1
      end,
      getpid = function()
        return 12345
      end,
      termopen = function(_, _)
        return 0
      end,
    },
    notify = function(_, _, _) end,
    log = {
      levels = {
        NONE = 0,
        ERROR = 1,
        WARN = 2,
        INFO = 3,
        DEBUG = 4,
        TRACE = 5,
      },
    },
    json = {
      encode = function(obj)
        -- Simple JSON encoding for testing
        if type(obj) == "table" then
          local pairs_array = {}
          for k, v in pairs(obj) do
            local key_str = '"' .. tostring(k) .. '"'
            local val_str
            if type(v) == "string" then
              val_str = '"' .. v .. '"'
            elseif type(v) == "number" then
              val_str = tostring(v)
            elseif type(v) == "table" then
              -- Simple array encoding
              local items = {}
              for _, item in ipairs(v) do
                table.insert(items, '"' .. tostring(item) .. '"')
              end
              val_str = "[" .. table.concat(items, ",") .. "]"
            else
              val_str = '"' .. tostring(v) .. '"'
            end
            table.insert(pairs_array, key_str .. ":" .. val_str)
          end
          return "{" .. table.concat(pairs_array, ",") .. "}"
        else
          return '"' .. tostring(obj) .. '"'
        end
      end,
      decode = function(json_str)
        -- Very basic JSON parsing for test purposes
        if json_str:match("^%s*{.*}%s*$") then
          local result = {}
          -- Extract key-value pairs - this is very basic
          for key, value in json_str:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
            result[key] = value
          end
          for key, value in json_str:gmatch('"([^"]+)"%s*:%s*(%d+)') do
            result[key] = tonumber(value)
          end
          return result
        end
        return {}
      end,
    },
    lsp = {}, -- Existing lsp mock part
    o = { ---@type vim_options_table
      columns = 80,
      lines = 24,
    },
    bo = setmetatable({}, { -- Mock for vim.bo and vim.bo[bufnr]
      __index = function(t, k)
        if type(k) == "number" then
          -- vim.bo[bufnr] accessed, return a new proxy table for this buffer
          if not t[k] then
            t[k] = {} ---@type vim_buffer_options_table
          end
          return t[k]
        end
        -- vim.bo.option_name (global buffer option)
        return nil -- Return nil or a default mock value if needed
      end, -- REMOVED COMMA from here (was after 'end')
      -- __newindex can be added here if setting options is needed for tests
      -- e.g., __newindex = function(t, k, v) rawset(t, k, v) end,
    }), ---@type vim_bo_proxy
    diagnostic = { ---@type vim_diagnostic_module
      get = function()
        return {}
      end,
      -- Add other vim.diagnostic functions as needed for tests
    },
    empty_dict = function()
      return {}
    end,
  } -- This is the closing brace for _G.vim table
end

-- Track the most recent fs_open mode so permission-intent assertions can read it.
_G._test_last_fs_open_mode = nil
-- Track the most recent fs_chmod call (path, mode) so the directory-permission
-- assertion can verify an existing dir gets tightened to 0700 on upgrade.
_G._test_last_fs_chmod = nil

-- Provide a vim.loop mock with a CSPRNG and atomic-write file primitives.
-- The fs_* helpers write to real files so get_auth_token round-trips work.
if not _G.vim.loop then
  _G.vim.loop = {}
end
do
  local loop = _G.vim.loop
  local open_files = {}

  -- Deterministic-but-varying byte source: differs per call so successive
  -- tokens are distinct (regression guard against the old seeded behavior).
  local random_counter = 0
  loop.random = function(n)
    random_counter = random_counter + 1
    local bytes = {}
    for i = 1, n do
      -- Mix the counter and index to vary bytes across calls and positions.
      bytes[i] = string.char((random_counter * 31 + i * 7) % 256)
    end
    return table.concat(bytes)
  end

  loop.fs_open = function(path, _flags, mode)
    _G._test_last_fs_open_mode = mode
    local fh = io.open(path, "wb")
    if not fh then
      return nil
    end
    local fd = #open_files + 1
    open_files[fd] = fh
    return fd
  end

  -- Mirror libuv's signature: fs_write(fd, data, offset). The production code
  -- now writes in a loop honoring the returned byte count and an offset, so
  -- seek to the offset before writing and report the number of bytes written.
  loop.fs_write = function(fd, data, offset)
    local fh = open_files[fd]
    if not fh then
      return nil
    end
    if offset then
      fh:seek("set", offset)
    end
    fh:write(data)
    return #data
  end

  loop.fs_close = function(fd)
    local fh = open_files[fd]
    if fh then
      fh:close()
      open_files[fd] = nil
    end
    return true
  end

  -- Mirror libuv's fs_unlink with the unlink(2) call itself, so a folder is refused (EISDIR on Linux, EPERM on macOS)
  -- as it is for the plugin, and a failure comes back as (nil, "NAME: message: path", "NAME") without raising.
  local ffi = require("ffi")
  pcall(ffi.cdef, "int unlink(const char *path);")
  local unlink_errors = {
    [1] = { "EPERM", "operation not permitted" },
    [2] = { "ENOENT", "no such file or directory" },
    [13] = { "EACCES", "permission denied" },
    [21] = { "EISDIR", "illegal operation on a directory" },
    [30] = { "EROFS", "read-only file system" },
  }
  loop.fs_unlink = function(path)
    if ffi.C.unlink(path) == 0 then
      return true
    end
    local code = ffi.errno()
    local known = unlink_errors[code] or { "E" .. code, "error " .. code }
    return nil, known[1] .. ": " .. known[2] .. ": " .. path, known[1]
  end

  -- Mirror libuv's fs_stat for a path: nil and an error for a missing path, else a table with the type. The shell's
  -- `test` follows symlinks as stat does, and it does not need read permission on the file, as stat does not.
  if not loop.fs_stat then
    loop.fs_stat = function(path)
      local function test(flag)
        local ok = os.execute("test " .. flag .. " " .. temp_dir.quote(path))
        return ok == 0 or ok == true
      end
      if test("-d") then
        return { type = "directory" }
      end
      if test("-f") then
        return { type = "file" }
      end
      if test("-p") then
        return { type = "fifo" }
      end
      if test("-S") then
        return { type = "socket" }
      end
      return nil, "ENOENT: no such file or directory", "ENOENT"
    end
  end
  -- fs_lstat does not follow a link: a link is of type "link", even one that points nowhere.
  if not loop.fs_lstat then
    loop.fs_lstat = function(path)
      local ok = os.execute("test -L " .. temp_dir.quote(path))
      if ok == 0 or ok == true then
        return { type = "link" }
      end
      return loop.fs_stat(path)
    end
  end

  -- Record chmod calls so tests can assert the lock dir is tightened to 0700.
  loop.fs_chmod = function(path, mode)
    _G._test_last_fs_chmod = { path = path, mode = mode }
    return true
  end

  -- Monotonic-ish clock used to keep the temp-file path unique across calls.
  local hrtime_counter = 0
  loop.hrtime = function()
    hrtime_counter = hrtime_counter + 1
    return hrtime_counter
  end
end

-- Whether this user is root. Root reads any file and opens any FIFO, whatever its mode.
local function running_as_root()
  local pipe = assert(io.popen("id -u"))
  local uid = pipe:read("*l")
  pipe:close()
  return uid == "0"
end

-- Runs a shell command that a test's setup needs, and fails the test when it exits with a status that is not 0.
-- `assert(os.execute(...))` never fails here: LuaJIT returns the raw status, 0 for success and 256 for exit status 1, and
-- every number is truthy. Lua 5.2 and later return true for success.
local function shell(command)
  local status = os.execute(command)
  assert(status == 0 or status == true, "failed: " .. command)
end

-- Makes a FIFO at `path` with `mode` (as a string such as "600"), or returns false when mkfifo is not there.
local function make_fifo(path, mode)
  local ok = os.execute("mkfifo -m " .. mode .. " " .. temp_dir.quote(path) .. " 2>/dev/null")
  return ok == 0 or ok == true
end

-- Makes a Unix socket file at `path` (python3 binds one and the file stays when it exits), or returns false.
local function make_socket(path)
  local ok = os.execute(
    "python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "
      .. temp_dir.quote(path)
      .. " 2>/dev/null"
  )
  return ok == 0 or ok == true
end

describe("Lockfile Module", function()
  local lockfile

  -- Save original vim functions/tables (not used in this test but kept for reference)
  -- luacheck: ignore
  local orig_vim = _G.vim
  local orig_fn_getcwd = vim.fn.getcwd
  local orig_lsp = vim.lsp
  -- luacheck: no ignore

  -- Create a mock for testing LSP client resolution
  local create_mock_env = function(api_version)
    -- Configure mock based on API version
    local mock_lsp = {}

    -- Test workspace folders data
    local test_workspace_data = {
      {
        config = {
          workspace_folders = {
            { uri = "file:///mock/folder1" },
            { uri = "file:///mock/folder2" },
          },
        },
      },
    }

    if api_version == "current" then
      -- Neovim 0.11+ API (get_clients)
      mock_lsp.get_clients = function()
        return test_workspace_data
      end
    elseif api_version == "legacy" then
      -- Neovim 0.8-0.10 API (get_active_clients)
      mock_lsp.get_active_clients = function()
        return test_workspace_data
      end
    end

    -- Apply mock
    vim.lsp = mock_lsp
  end

  setup(function()
    -- Mock required vim functions before loading the module
    vim.fn.getcwd = function()
      return "/mock/cwd"
    end

    home = temp_dir.new()
    os.execute("mkdir -p " .. temp_dir.quote(home .. "/.claude/ide"))

    -- The module picks its lock folder from CLAUDE_CONFIG_DIR once, when it loads. Hide the caller's value for that
    -- one load, so the tests use only the private home and never read or write the caller's config folder.
    local real_getenv = os.getenv
    os.getenv = function(name)
      if name == "CLAUDE_CONFIG_DIR" then
        return nil
      end
      return real_getenv(name)
    end

    -- Load the lockfile module for all tests
    package.loaded["claudecode.lockfile"] = nil -- Clear any previous requires
    local loaded, load_error = pcall(function()
      lockfile = require("claudecode.lockfile")
    end)
    os.getenv = real_getenv
    assert(loaded, load_error)
  end)

  teardown(function()
    temp_dir.remove(home)

    -- Restore original vim
    if real_vim then
      _G.vim = real_vim
    end
  end)

  describe("get_workspace_folders()", function()
    before_each(function()
      -- Ensure consistent path
      vim.fn.getcwd = function()
        return "/mock/cwd"
      end
    end)

    after_each(function()
      -- Restore lsp table to clean state
      vim.lsp = {}
    end)

    it("should include the current working directory", function()
      local folders = lockfile.get_workspace_folders()
      assert("/mock/cwd" == folders[1])
    end)

    it("should work with current Neovim API (get_clients)", function()
      -- Set up the current API mock
      create_mock_env("current")

      -- Test the function
      local folders = lockfile.get_workspace_folders()

      -- Verify results
      assert(3 == #folders) -- cwd + 2 workspace folders
      assert("/mock/folder1" == folders[2])
      assert("/mock/folder2" == folders[3])
    end)

    it("should work with legacy Neovim API (get_active_clients)", function()
      -- Set up the legacy API mock
      create_mock_env("legacy")

      -- Test the function
      local folders = lockfile.get_workspace_folders()

      -- Verify results
      assert(3 == #folders) -- cwd + 2 workspace folders
      assert("/mock/folder1" == folders[2])
      assert("/mock/folder2" == folders[3])
    end)

    it("should handle duplicate folder paths", function()
      -- Set up a mock with duplicates
      vim.lsp = {
        get_clients = function()
          return {
            {
              config = {
                workspace_folders = {
                  { uri = "file:///mock/cwd" }, -- Same as cwd
                  { uri = "file:///mock/folder" },
                  { uri = "file:///mock/folder" }, -- Duplicate
                },
              },
            },
          }
        end,
      }

      -- Test the function
      local folders = lockfile.get_workspace_folders()

      -- Verify results
      assert(2 == #folders) -- cwd + 1 unique workspace folder
    end)
  end)

  describe("lock directory", function()
    it("should stay inside the private test home whatever CLAUDE_CONFIG_DIR is", function()
      -- The suite creates, reads and removes lock files. A lock_dir outside `home` would make it write into the
      -- caller's real config folder, or fail when that folder has no ide/ subfolder.
      assert(home .. "/.claude/ide" == lockfile.lock_dir, "lock_dir is " .. tostring(lockfile.lock_dir))
    end)
  end)

  describe("remove()", function()
    local real_fs_unlink

    before_each(function()
      real_fs_unlink = vim.loop.fs_unlink
    end)

    after_each(function()
      vim.loop.fs_unlink = real_fs_unlink
    end)

    it("should delete the lock file and report success", function()
      local port = 12350
      local created, lock_path = lockfile.create(port)
      assert(created == true)

      local success, err = lockfile.remove(port)

      assert(success == true)
      assert(err == nil)
      assert(vim.fn.filereadable(lock_path) == 0)
    end)

    it("should report a failure when fs_unlink returns nil and an error instead of raising", function()
      local port = 12351
      local created, lock_path = lockfile.create(port)
      assert(created == true)

      -- fs_unlink reports a failure such as a read-only folder as (nil, message, name), without raising.
      vim.loop.fs_unlink = function(path)
        assert(path == lock_path)
        return nil, "EACCES: permission denied: " .. lock_path, "EACCES"
      end

      local success, err = lockfile.remove(port)
      vim.loop.fs_unlink = real_fs_unlink

      -- The file is still there, so remove must not say that it worked.
      local still_there = vim.fn.filereadable(lock_path) == 1
      os.remove(lock_path)

      assert(still_there)
      assert(success == false, "remove returned " .. tostring(success) .. " while the lock file stays")
      assert("string" == type(err))
      assert(err:find("Failed to remove lock file", 1, true))
      assert(err:find("permission denied", 1, true))
    end)

    -- Deleting a file needs write permission on its folder, not read permission on the file.
    -- Whether a name is there: a link counts, even one that points nowhere.
    local function exists(path)
      local ok = os.execute("test -e " .. temp_dir.quote(path) .. " || test -L " .. temp_dir.quote(path))
      return ok == 0 or ok == true
    end

    it("should delete a lock file that exists but cannot be read", function()
      local port = 12353
      local created, lock_path = lockfile.create(port)
      assert(created == true)
      os.execute("chmod 000 " .. temp_dir.quote(lock_path))

      local probe = io.open(lock_path, "r")
      if probe then
        probe:close()
        os.remove(lock_path)
        return pending("this user can read a file with mode 000 (root)")
      end

      local success, err = lockfile.remove(port)
      local still_there = exists(lock_path)
      if still_there then
        os.execute("chmod 600 " .. temp_dir.quote(lock_path))
        os.remove(lock_path)
      end

      assert(success == true, "remove returned " .. tostring(success) .. ": " .. tostring(err))
      assert(err == nil)
      assert(not still_there, "the lock file stays")
    end)

    it("should report that a lock file that is missing does not exist", function()
      local port = 12354
      local lock_path = lockfile.lock_dir .. "/" .. port .. ".lock"
      assert(not exists(lock_path))

      local success, err = lockfile.remove(port)

      assert(success == false)
      assert(err == "Lock file does not exist: " .. lock_path, tostring(err))
    end)

    it("should not delete a folder that is named like a lock file", function()
      local port = 12355
      local lock_path = lockfile.lock_dir .. "/" .. port .. ".lock"
      shell("mkdir " .. temp_dir.quote(lock_path))

      local success, err = lockfile.remove(port)
      local still_there = exists(lock_path)
      os.execute("rmdir " .. temp_dir.quote(lock_path))

      assert(success == false)
      assert(err == "Lock file does not exist: " .. lock_path, tostring(err))
      assert(still_there, "the folder is gone")
    end)

    it("should report the fs_unlink error and keep the lock file when the folder is read-only", function()
      local port = 12356
      local created, lock_path = lockfile.create(port)
      assert(created == true)
      os.execute("chmod 555 " .. temp_dir.quote(lockfile.lock_dir))

      local probe_path = lockfile.lock_dir .. "/probe"
      local probe = io.open(probe_path, "w")
      if probe then
        probe:close()
        os.remove(probe_path)
        os.execute("chmod 755 " .. temp_dir.quote(lockfile.lock_dir))
        os.remove(lock_path)
        return pending("this user can write into a folder with mode 555 (root)")
      end

      local success, err = lockfile.remove(port)
      os.execute("chmod 755 " .. temp_dir.quote(lockfile.lock_dir))
      local still_there = exists(lock_path)
      os.remove(lock_path)

      assert(success == false, "remove returned " .. tostring(success))
      assert("string" == type(err))
      assert(err:find("Failed to remove lock file", 1, true), err)
      assert(err:find(lock_path, 1, true), err)
      assert(err:lower():find("permission denied", 1, true), err)
      assert(still_there, "the lock file is gone")
    end)

    -- Another process of the same user can replace the lock file with a folder between the check and the delete.
    -- `fs_unlink` refuses a folder, where `os.remove` would delete an empty one. The folder takes the file's place right
    -- after the first call of fs_stat or fs_lstat that names the lock path, so the test does not depend on which one
    -- the plugin calls.
    it("should not delete a folder that takes the place of the lock file after the check", function()
      for _, mode in ipairs({ "000", "600" }) do
        local port = 12365
        local lock_path = lockfile.lock_dir .. "/" .. port .. ".lock"
        local quoted = temp_dir.quote(lock_path)
        local file = assert(io.open(lock_path, "w"))
        file:close()
        shell("chmod " .. mode .. " " .. quoted)

        local replaced = false
        local real_stat, real_lstat = vim.loop.fs_stat, vim.loop.fs_lstat
        local function replace_after(real)
          return function(path, ...)
            local stat, err, name = real(path, ...)
            if path == lock_path and not replaced then
              replaced = true
              shell("rm -f " .. quoted .. " && mkdir " .. quoted)
            end
            return stat, err, name
          end
        end
        vim.loop.fs_stat, vim.loop.fs_lstat = replace_after(real_stat), replace_after(real_lstat)
        local called, success, err = pcall(lockfile.remove, port)
        vim.loop.fs_stat, vim.loop.fs_lstat = real_stat, real_lstat

        local is_folder = os.execute("test -d " .. quoted)
        local folder_stays = is_folder == 0 or is_folder == true
        os.execute("rm -rf " .. quoted)

        assert(called, "remove raised: " .. tostring(success))
        assert(replaced, "mode " .. mode .. ": the folder never took the place of the file")
        assert(success == false, "mode " .. mode .. ": remove returned " .. tostring(success) .. ": " .. tostring(err))
        assert(folder_stays, "mode " .. mode .. ": remove deleted the folder")
        assert(err:find("Failed to remove lock file", 1, true), err)
      end
    end)

    -- A link is a name that `remove` can delete. It deletes the link and never its target.
    local function removes_only_the_name(port, make_name)
      local lock_path = lockfile.lock_dir .. "/" .. port .. ".lock"
      local still_there = make_name(lock_path)

      local success, err = lockfile.remove(port)
      local name_stays = exists(lock_path)
      local target_stays = still_there()
      os.execute("rm -rf " .. temp_dir.quote(lock_path))

      assert(success == true, "remove returned " .. tostring(success) .. ": " .. tostring(err))
      assert(not name_stays, "the name stays")
      assert(target_stays, "the target is gone")
    end

    it("should remove a link that points nowhere", function()
      removes_only_the_name(12366, function(lock_path)
        shell("ln -s " .. temp_dir.quote(lockfile.lock_dir .. "/nowhere") .. " " .. temp_dir.quote(lock_path))
        return function()
          return true
        end
      end)
    end)

    it("should remove a link to the lock file of another port and keep that file", function()
      removes_only_the_name(12367, function(lock_path)
        local created, other_path = lockfile.create(12368)
        assert(created == true)
        shell("ln -s " .. temp_dir.quote(other_path) .. " " .. temp_dir.quote(lock_path))
        return function()
          -- The other file is still there, and it still holds its content (the test reads no content: test -s).
          local ok = os.execute("test -s " .. temp_dir.quote(other_path))
          os.remove(other_path)
          return ok == 0 or ok == true
        end
      end)
    end)

    it("should remove one name of a hard link and keep the other name", function()
      removes_only_the_name(12369, function(lock_path)
        local created, other_path = lockfile.create(12370)
        assert(created == true)
        shell("ln " .. temp_dir.quote(other_path) .. " " .. temp_dir.quote(lock_path))
        return function()
          local ok = os.execute("test -s " .. temp_dir.quote(other_path))
          os.remove(other_path)
          return ok == 0 or ok == true
        end
      end)
    end)

    it("should remove a link to a folder and keep the folder and what it holds", function()
      removes_only_the_name(12371, function(lock_path)
        local folder = lockfile.lock_dir .. "/folder-of-12371"
        shell("mkdir " .. temp_dir.quote(folder) .. " && touch " .. temp_dir.quote(folder .. "/keep"))
        shell("ln -s " .. temp_dir.quote(folder) .. " " .. temp_dir.quote(lock_path))
        return function()
          local ok = os.execute("test -f " .. temp_dir.quote(folder .. "/keep"))
          os.execute("rm -rf " .. temp_dir.quote(folder))
          return ok == 0 or ok == true
        end
      end)
    end)

    -- A FIFO or a socket at the lock path was deleted before, because `filereadable` let it through. It is still.
    it("should delete a FIFO at the lock path", function()
      local port = 12358
      local lock_path = lockfile.lock_dir .. "/" .. port .. ".lock"
      if not make_fifo(lock_path, "600") then
        return pending("cannot make a FIFO here")
      end

      local success, err = lockfile.remove(port)
      local still_there = exists(lock_path)
      if still_there then
        os.remove(lock_path)
      end

      assert(success == true, "remove returned " .. tostring(success) .. ": " .. tostring(err))
      assert(not still_there, "the FIFO stays")
    end)

    it("should delete a socket at the lock path", function()
      local port = 12359
      local lock_path = lockfile.lock_dir .. "/" .. port .. ".lock"
      if not make_socket(lock_path) then
        return pending("cannot make a socket here")
      end

      local success, err = lockfile.remove(port)
      local still_there = exists(lock_path)
      if still_there then
        os.remove(lock_path)
      end

      assert(success == true, "remove returned " .. tostring(success) .. ": " .. tostring(err))
      assert(not still_there, "the socket stays")
    end)

    it("should report a failure when fs_unlink raises", function()
      local port = 12352
      local created, lock_path = lockfile.create(port)
      assert(created == true)

      vim.loop.fs_unlink = function()
        error("boom")
      end

      local success, err = lockfile.remove(port)
      vim.loop.fs_unlink = real_fs_unlink
      os.remove(lock_path)

      assert(success == false)
      assert(err:find("Failed to remove lock file", 1, true))
      assert(err:find("boom", 1, true))
    end)
  end)

  describe("update()", function()
    it("should not exist, because a rewritten lock file holds a token that the running server does not know", function()
      -- update(port) removed the file and called create(port) without a token, so the new file got a fresh random
      -- token while the server kept the old one. Nothing called it. A caller that needs a new file calls create
      -- with the server's token.
      assert(lockfile.update == nil)
    end)
  end)

  describe("authentication token functionality", function()
    it("should generate auth tokens", function()
      local token1 = lockfile.generate_auth_token()
      local token2 = lockfile.generate_auth_token()

      -- Tokens should be strings
      assert("string" == type(token1))
      assert("string" == type(token2))

      -- Tokens should be different (regression guard against the old
      -- seed-once PRNG which produced identical tokens within a process)
      assert(token1 ~= token2)

      -- Tokens should be lowercase hex with at least 16 chars (32 for 16 bytes)
      assert(token1:match("^[0-9a-f]+$"))
      assert(token2:match("^[0-9a-f]+$"))
      assert(#token1 >= 16)
      assert(#token2 >= 16)
      assert(32 == #token1)
      assert(32 == #token2)
    end)

    it("should create lock files with auth tokens", function()
      local port = 12345
      local success, lock_path, auth_token = lockfile.create(port)

      assert(success == true)
      assert("string" == type(lock_path))
      assert("string" == type(auth_token))

      -- Should be able to read the auth token back
      local read_success, read_token, read_error = lockfile.get_auth_token(port)
      assert(read_success == true)
      assert(auth_token == read_token)
      assert(read_error == nil)
    end)

    it("should create lock files with pre-generated auth tokens", function()
      local port = 12346
      local preset_token = "test-auth-token-12345"
      local success, lock_path, returned_token = lockfile.create(port, preset_token)

      assert(success == true)
      assert("string" == type(lock_path))
      assert(preset_token == returned_token)

      -- Should be able to read the preset token back
      local read_success, read_token, read_error = lockfile.get_auth_token(port)
      assert(read_success == true)
      assert(preset_token == read_token)
      assert(read_error == nil)
    end)

    it("should handle missing lock files when reading auth tokens", function()
      local nonexistent_port = 99999
      local success, token, error = lockfile.get_auth_token(nonexistent_port)

      assert(success == false)
      assert(token == nil)
      assert("string" == type(error))
      assert(error:find("Lock file does not exist"))
    end)

    it("should say that a lock file that is missing does not exist", function()
      local port = 12360
      local lock_path = lockfile.lock_dir .. "/" .. port .. ".lock"

      local success, token, err = lockfile.get_auth_token(port)

      assert(success == false)
      assert(token == nil, "a token came back")
      assert(err == "Lock file does not exist: " .. lock_path, tostring(err))
    end)

    it("should refuse a lock file that exists but cannot be read, and say that it cannot be read", function()
      local port = 12361
      local created, lock_path = lockfile.create(port)
      assert(created == true)
      os.execute("chmod 000 " .. temp_dir.quote(lock_path))

      local probe = io.open(lock_path, "r")
      if probe then
        probe:close()
        os.remove(lock_path)
        return pending("this user can read a file with mode 000 (root)")
      end

      local success, token, err = lockfile.get_auth_token(port)
      os.execute("chmod 600 " .. temp_dir.quote(lock_path))
      os.remove(lock_path)

      -- The messages are checked here, never the token or the file's content.
      assert(success == false)
      assert(token == nil, "a token came back")
      assert("string" == type(err))
      assert(err:find("Lock file exists but cannot be read: ", 1, true) == 1, err)
      assert(err:find(lock_path, 1, true), err)
      assert(err:find("Permission denied", 1, true), err)
      assert(not err:find("does not exist", 1, true), err)
    end)

    it("should say that a FIFO that cannot be read exists but cannot be read", function()
      local port = 12363
      local lock_path = lockfile.lock_dir .. "/" .. port .. ".lock"
      -- Root opens any FIFO whatever its mode, and the open would wait for a writer.
      if running_as_root() then
        return pending("root opens a FIFO with mode 000")
      end
      if not make_fifo(lock_path, "000") then
        return pending("cannot make a FIFO here")
      end

      local success, token, err = lockfile.get_auth_token(port)
      os.remove(lock_path)

      assert(success == false)
      assert(token == nil, "a token came back")
      assert(tostring(err):find("Lock file exists but cannot be read: ", 1, true) == 1, tostring(err))
    end)

    it("should say that a socket at the lock path exists but cannot be read", function()
      local port = 12364
      local lock_path = lockfile.lock_dir .. "/" .. port .. ".lock"
      if not make_socket(lock_path) then
        return pending("cannot make a socket here")
      end

      local success, token, err = lockfile.get_auth_token(port)
      os.remove(lock_path)

      assert(success == false)
      assert(token == nil, "a token came back")
      assert(tostring(err):find("Lock file exists but cannot be read: ", 1, true) == 1, tostring(err))
    end)

    it("should say that a folder named like a lock file is not a lock file", function()
      local port = 12362
      local lock_path = lockfile.lock_dir .. "/" .. port .. ".lock"
      shell("mkdir " .. temp_dir.quote(lock_path))

      local success, token, err = lockfile.get_auth_token(port)
      os.execute("rmdir " .. temp_dir.quote(lock_path))

      assert(success == false)
      assert(token == nil, "a token came back")
      assert(err == "Lock file does not exist: " .. lock_path, tostring(err))
    end)

    it("should say that a link that points nowhere is no lock file", function()
      local port = 12372
      local lock_path = lockfile.lock_dir .. "/" .. port .. ".lock"
      shell("ln -s " .. temp_dir.quote(lockfile.lock_dir .. "/nowhere") .. " " .. temp_dir.quote(lock_path))

      local success, token, err = lockfile.get_auth_token(port)
      os.execute("rm -f " .. temp_dir.quote(lock_path))

      assert(success == false)
      assert(token == nil, "a token came back")
      assert(err == "Lock file does not exist: " .. lock_path, tostring(err))
    end)

    it("should write the lock file with 0600 permissions", function()
      _G._test_last_fs_open_mode = nil
      local port = 12347
      local success = lockfile.create(port)

      assert(success == true)
      -- The atomic write must request mode 0600 (octal 384) on the temp file.
      assert(tonumber("600", 8) == _G._test_last_fs_open_mode)
    end)

    it("should create the lock directory with 0700 permissions", function()
      local captured_mkdir_mode
      local orig_mkdir = vim.fn.mkdir
      vim.fn.mkdir = function(path, flags, mode)
        captured_mkdir_mode = mode
        return orig_mkdir(path, flags, mode)
      end

      _G._test_last_fs_chmod = nil
      local port = 12348
      local success = lockfile.create(port)
      vim.fn.mkdir = orig_mkdir

      assert(success == true)
      -- New directories get 0700 from mkdir's mode argument, passed as an octal
      -- number (tonumber("700", 8)); the string "0700" would be coerced to
      -- decimal 700 and apply the wrong mode to freshly-created parents...
      assert(tonumber("700", 8) == captured_mkdir_mode)
      -- ...but mkdir's mode is a no-op for a pre-existing dir, so an explicit
      -- chmod must also tighten the lock dir to 0700 on upgrade.
      assert(_G._test_last_fs_chmod ~= nil)
      assert(lockfile.lock_dir == _G._test_last_fs_chmod.path)
      assert(tonumber("700", 8) == _G._test_last_fs_chmod.mode)
    end)

    it("should write the full lock file content when fs_write reports short writes", function()
      -- Force fs_write to write at most one byte per call so the production
      -- write loop has to iterate; the resulting lock file must be complete.
      local loop = vim.loop
      local orig_fs_write = loop.fs_write
      loop.fs_write = function(fd, data, offset)
        return orig_fs_write(fd, data:sub(1, 1), offset)
      end

      local port = 12349
      local success, _, auth_token = lockfile.create(port)
      loop.fs_write = orig_fs_write

      assert(success == true)
      assert("string" == type(auth_token))

      -- The token must round-trip, proving the JSON was written in full.
      local read_success, read_token = lockfile.get_auth_token(port)
      assert(read_success == true)
      assert(auth_token == read_token)
    end)
  end)
end)

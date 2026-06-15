-- Tests for lockfile module

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
        -- Use a temp directory that actually exists
        local temp_dir = os.getenv("TMPDIR") or "/tmp"
        return select(1, path:gsub("~", temp_dir .. "/claude_test"))
      end,
      -- Add other vim.fn mocks as needed by lockfile tests
      -- For now, only adding what's explicitly used or causing major type issues
      filereadable = function(path)
        -- Check if file actually exists
        local file = io.open(path, "r")
        if file then
          file:close()
          return 1
        else
          return 0
        end
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

  loop.fs_unlink = function(path)
    os.remove(path)
    return true
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

    -- Create test directory
    local temp_dir = os.getenv("TMPDIR") or "/tmp"
    local test_dir = temp_dir .. "/claude_test/.claude/ide"
    os.execute("mkdir -p '" .. test_dir .. "'")

    -- Load the lockfile module for all tests
    package.loaded["claudecode.lockfile"] = nil -- Clear any previous requires
    lockfile = require("claudecode.lockfile")
  end)

  teardown(function()
    -- Clean up test files
    local temp_dir = os.getenv("TMPDIR") or "/tmp"
    local test_dir = temp_dir .. "/claude_test"
    os.execute("rm -rf '" .. test_dir .. "'")

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

  describe("build_ide_name (via lockfile.create)", function()
    local orig_getenv
    local orig_system
    local orig_getcwd

    local function get_ide_name_from_lock(port)
      local temp_dir = os.getenv("TMPDIR") or "/tmp"
      local lock_path = temp_dir .. "/claude_test/.claude/ide/" .. port .. ".lock"
      local f = io.open(lock_path, "r")
      if not f then
        return nil
      end
      local content = f:read("*a")
      f:close()
      return content:match('"ideName"%s*:%s*"([^"]*)"')
    end

    before_each(function()
      orig_getenv = os.getenv
      orig_system = vim.fn.system
      orig_getcwd = vim.fn.getcwd
    end)

    after_each(function()
      os.getenv = orig_getenv
      vim.fn.system = orig_system
      vim.fn.getcwd = orig_getcwd
    end)

    it("should use override when provided", function()
      os.getenv = function(key)
        if key == "TMUX" then
          return nil
        end
        return orig_getenv(key)
      end

      local success = lockfile.create(23001, "test-token-override-123", { override = "My Custom Label" })
      assert(success == true)
      assert("My Custom Label" == get_ide_name_from_lock(23001))
    end)

    it("should fall through to cwd when override is empty string", function()
      os.getenv = function(key)
        if key == "TMUX" then
          return nil
        end
        if key == "HOME" then
          return "/home/testuser"
        end
        return orig_getenv(key)
      end
      vim.fn.getcwd = function()
        return "/home/testuser/projects/myproject"
      end

      local success = lockfile.create(23002, "test-token-empty-override-12", { override = "" })
      assert(success == true)
      assert("Neovim [~/projects/myproject]" == get_ide_name_from_lock(23002))
    end)

    it("should abbreviate HOME in cwd when not in tmux", function()
      os.getenv = function(key)
        if key == "TMUX" then
          return nil
        end
        if key == "HOME" then
          return "/home/testuser"
        end
        return orig_getenv(key)
      end
      vim.fn.getcwd = function()
        return "/home/testuser/code/myrepo"
      end

      local success = lockfile.create(23003, "test-token-cwd-abbrev-12345", {})
      assert(success == true)
      assert("Neovim [~/code/myrepo]" == get_ide_name_from_lock(23003))
    end)

    it("should use full cwd when not under HOME", function()
      os.getenv = function(key)
        if key == "TMUX" then
          return nil
        end
        if key == "HOME" then
          return "/home/testuser"
        end
        return orig_getenv(key)
      end
      vim.fn.getcwd = function()
        return "/opt/projects/myrepo"
      end

      local success = lockfile.create(23004, "test-token-cwd-full-1234567", {})
      assert(success == true)
      assert("Neovim [/opt/projects/myrepo]" == get_ide_name_from_lock(23004))
    end)

    it("should include tmux session and window when inside tmux", function()
      os.getenv = function(key)
        if key == "TMUX" then
          return "/tmp/tmux-1000/default,12345,0"
        end
        return orig_getenv(key)
      end
      vim.fn.system = function(cmd)
        if cmd:find("#S") then
          return "work\n"
        end
        if cmd:find("#W") then
          return "editor\n"
        end
        return ""
      end

      local success = lockfile.create(23005, "test-token-tmux-no-pane-123", { tmux_include_pane = false })
      assert(success == true)
      assert("Neovim [tmux:work:editor]" == get_ide_name_from_lock(23005))
    end)

    it("should include pane index when tmux_include_pane is true", function()
      os.getenv = function(key)
        if key == "TMUX" then
          return "/tmp/tmux-1000/default,12345,0"
        end
        return orig_getenv(key)
      end
      vim.fn.system = function(cmd)
        if cmd:find("#S") then
          return "work\n"
        end
        if cmd:find("#W") then
          return "editor\n"
        end
        if cmd:find("#P") then
          return "2\n"
        end
        return ""
      end

      local success = lockfile.create(23006, "test-token-tmux-with-pane-12", { tmux_include_pane = true })
      assert(success == true)
      assert("Neovim [tmux:work:editor:2]" == get_ide_name_from_lock(23006))
    end)

    it("should default to cwd label when ide_name_config is nil", function()
      os.getenv = function(key)
        if key == "TMUX" then
          return nil
        end
        if key == "HOME" then
          return "/home/testuser"
        end
        return orig_getenv(key)
      end
      vim.fn.getcwd = function()
        return "/home/testuser/work"
      end

      local success = lockfile.create(23007, "test-token-nil-config-12345", nil)
      assert(success == true)
      assert("Neovim [~/work]" == get_ide_name_from_lock(23007))
    end)
  end)
end)

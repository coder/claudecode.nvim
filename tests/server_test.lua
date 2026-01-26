-- Create minimal vim mock if it doesn't exist
if not _G.vim then
  _G.vim = { ---@type vim_global_api
    schedule_wrap = function(fn)
      return fn
    end,
    deepcopy = function(t)
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

    tbl_deep_extend = function(behavior, ...)
      local result = {}
      local tables = { ... }

      for _, tbl in ipairs(tables) do
        for k, v in pairs(tbl) do
          if type(v) == "table" and type(result[k]) == "table" then
            result[k] = _G.vim.tbl_deep_extend(behavior, result[k], v)
          else
            result[k] = v
          end
        end
      end

      return result
    end,

    json = {
      encode = function(data)
        return "{}"
      end,
      decode = function(json_str)
        return {}
      end,
    },

    loop = {
      new_tcp = function()
        return {
          bind = function(self, host, port)
            return true
          end,
          listen = function(self, backlog, callback)
            return true
          end,
          accept = function(self, client)
            return true
          end,
          read_start = function(self, callback)
            return true
          end,
          write = function(self, data, callback)
            if callback then
              callback()
            end
            return true
          end,
          close = function(self)
            return true
          end,
          is_closing = function(self)
            return false
          end,
        }
      end,
      new_timer = function()
        return {
          start = function(self, timeout, repeat_interval, callback)
            return true
          end,
          stop = function(self)
            return true
          end,
          close = function(self)
            return true
          end,
        }
      end,
      now = function()
        return os.time() * 1000
      end,
    },

    schedule = function(callback)
      callback()
    end,

    -- Added notify and log mocks
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
    o = { ---@type vim_options_table
      columns = 80,
      lines = 24,
    },
    bo = setmetatable({}, {
      __index = function(t, k)
        if type(k) == "number" then
          if not t[k] then
            t[k] = {} -- Return a new table for vim.bo[bufnr]
          end
          return t[k]
        end
        return nil
      end,
    }),
    diagnostic = {
      get = function()
        return {}
      end,
      -- Add other vim.diagnostic functions if needed by tests
    },
    empty_dict = function()
      return {}
    end,
    cmd = function() end, ---@type fun(command: string):nil
    api = {}, ---@type table
    fn = { ---@type vim_fn_table
      mode = function()
        return "n"
      end,
      delete = function(_, _)
        return 0
      end,
      filereadable = function(_)
        return 1
      end,
      fnamemodify = function(fname, _)
        return fname
      end,
      expand = function(s, _)
        return s
      end,
      getcwd = function()
        return "/mock/cwd"
      end,
      mkdir = function(_, _, _)
        return 1
      end,
      buflisted = function(_)
        return 1
      end,
      bufname = function(_)
        return "mockbuffer"
      end,
      bufnr = function(_)
        return 1
      end,
      win_getid = function()
        return 1
      end,
      win_gotoid = function(_)
        return true
      end,
      line = function(_)
        return 1
      end,
      col = function(_)
        return 1
      end,
      virtcol = function(_)
        return 1
      end,
      getpos = function(_)
        return { 0, 1, 1, 0 }
      end,
      setpos = function(_, _)
        return true
      end,
      tempname = function()
        return "/tmp/mocktemp"
      end,
      globpath = function(_, _)
        return ""
      end,
      termopen = function(_, _)
        return 0
      end,
      stdpath = function(_)
        return "/mock/stdpath"
      end,
      json_encode = function(_)
        return "{}"
      end,
      json_decode = function(_)
        return {}
      end,
    },
    fs = { remove = function() end }, ---@type vim_fs_module
  }
end

describe("Server module", function()
  local server

  setup(function()
    -- Reset the module
    package.loaded["claudecode.server.init"] = nil -- Also update package.loaded key

    server = require("claudecode.server.init")
  end)

  teardown(function()
    if server.state.server then
      server.stop()
    end
  end)

  it("should have an empty initial state", function()
    assert(type(server.state) == "table")
    assert(server.state.server == nil)
    assert(server.state.port == nil)
    assert(type(server.state.handlers) == "table")
  end)

  it("should have get_status function", function()
    local status = server.get_status()

    assert(type(status) == "table")
    assert(status.running == false)
    assert(status.port == nil)
    assert(status.client_count == 0)
  end)

  it("should start and stop the server", function()
    local config = {
      port_range = {
        min = 10000,
        max = 65535,
      },
    }

    local start_success, result = server.start(config)

    assert(start_success == true)
    assert(type(result) == "number")
    assert(server.state.server ~= nil)
    assert(server.state.port ~= nil)

    local stop_success = server.stop()

    assert(stop_success == true)
    assert(server.state.server == nil)
    assert(server.state.port == nil)

    local status = server.get_status()
    assert(status.running == false)
    assert(status.port == nil)
    assert(status.client_count == 0)
  end)

  it("should not stop the server if not running", function()
    -- Ensure server is not running
    if server.state.server then
      server.stop()
    end

    local success, error = server.stop()

    assert(success == false)
    assert("Server not running" == error)
  end)
end)

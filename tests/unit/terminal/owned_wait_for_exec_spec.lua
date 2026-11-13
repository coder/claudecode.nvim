-- A job that was just started can still be a fork of Neovim: its child has not run exec yet, and a jobstop then can end
-- Neovim with SIGHUP. owned.wait_for_exec waits until the child has the name of its command. native.close and
-- snacks.close call it for a young job, and the stop in owned.lua calls it for every job (it has no start time).
describe("claudecode.terminal.owned wait_for_exec", function()
  local owned
  local original_vim
  local state
  local restore_proc

  -- Neovim reads /proc/<pid>/comm on Linux, and asks nvim_get_proc where /proc is missing (macOS, the BSDs). `names` is
  -- false for no /proc, or a function(pid) that returns the name of a process or nil for one that is gone. "self" is
  -- Neovim.
  local function stub_proc(names)
    local open = io.open
    rawset(io, "open", function(path, mode)
      local pid = type(path) == "string" and path:match("^/proc/([^/]+)/comm$")
      if not pid then
        return open(path, mode)
      end
      local name = names and names(pid)
      if not name then
        return nil
      end
      return {
        read = function()
          return name
        end,
        close = function() end,
      }
    end)
    return function()
      rawset(io, "open", open)
    end
  end

  before_each(function()
    original_vim = _G.vim
    state = { now = 0, waits = {}, jobs = { [7] = true }, child_name = "nvim" }
    _G.vim = {
      loop = {
        hrtime = function()
          return state.now
        end,
      },
      fn = {
        getpid = function()
          return 100
        end,
        jobpid = function(id)
          if not state.jobs[id] then
            error("Vim:E900: Invalid channel id")
          end
          return 200
        end,
      },
      api = {
        nvim_get_proc = function(pid)
          if pid == 100 then
            return { name = "nvim" }
          end
          if state.child_name then
            return { name = state.child_name }
          end
          error("process not found")
        end,
      },
      -- The first call looks at the child twice before it runs exec, and once after.
      wait = function(timeout, condition)
        table.insert(state.waits, timeout)
        if state.runs_exec then
          local looks = {}
          for _ = 1, 2 do
            table.insert(looks, condition())
          end
          state.child_name = "sh"
          table.insert(looks, condition())
          state.looks = looks
          return looks[#looks]
        end
        return condition()
      end,
    }
    package.loaded["claudecode.terminal.owned"] = nil
    owned = require("claudecode.terminal.owned")
    restore_proc = stub_proc(function(pid)
      if pid == "self" or pid == "100" then
        return "nvim"
      end
      if pid == "200" then
        return state.child_name
      end
    end)
  end)

  after_each(function()
    restore_proc()
    _G.vim = original_vim
    package.loaded["claudecode.terminal.owned"] = nil
  end)

  it("waits up to 1 s until the child has another name than Neovim (names from /proc)", function()
    state.runs_exec = true

    owned.wait_for_exec(7)

    assert.are.same({ 1000 }, state.waits)
    assert.are.same({ false, false, true }, state.looks)
  end)

  it("takes the names from nvim_get_proc where /proc is missing", function()
    restore_proc()
    restore_proc = stub_proc(false)
    state.runs_exec = true

    owned.wait_for_exec(7)

    assert.are.same({ 1000 }, state.waits)
    assert.are.same({ false, false, true }, state.looks)
  end)

  it("returns after 1 s when the child never runs exec", function()
    owned.wait_for_exec(7)

    assert.are.same({ 1000 }, state.waits)
    assert.are.equal("nvim", state.child_name)
  end)

  it("does not wait for a job that has no pid", function()
    owned.wait_for_exec(8)

    assert.are.same({}, state.waits)
  end)

  it("does not wait when the names cannot be read", function()
    restore_proc()
    restore_proc = stub_proc(false)
    _G.vim.api.nvim_get_proc = function()
      error("ps is missing")
    end

    owned.wait_for_exec(7)

    assert.are.same({}, state.waits)
  end)

  describe("is_young", function()
    it("is false when the start time is unknown", function()
      assert.is_false(owned.is_young(nil))
    end)

    it("is true for a job that started less than 10 s ago", function()
      state.now = 10 * 1e9 - 1

      assert.is_true(owned.is_young(0))
    end)

    it("is false for a job that started 10 s ago or more", function()
      state.now = 10 * 1e9

      assert.is_false(owned.is_young(0))
    end)
  end)

  describe("the stop of a marked buffer", function()
    local events

    before_each(function()
      events = {}
      state.buffers = { [3] = true }
      local mark = owned.SNACKS_MARK
      _G.vim.b = setmetatable({}, {
        __index = function(_, buf)
          return state.buffers[buf] and { [mark] = true } or {}
        end,
      })
      _G.vim.bo = setmetatable({}, {
        __index = function()
          return { channel = 7 }
        end,
      })
      _G.vim.api.nvim_list_bufs = function()
        return { 3 }
      end
      _G.vim.api.nvim_buf_is_valid = function(buf)
        return state.buffers[buf] ~= nil
      end
      _G.vim.api.nvim_create_autocmd = function() end
      _G.vim.api.nvim_buf_delete = function(buf)
        table.insert(events, "delete")
        state.buffers[buf] = nil
      end
      _G.vim.fn.jobstop = function(id)
        table.insert(events, "jobstop")
        state.jobs[id] = nil
        return 1
      end
      package.loaded["claudecode.terminal.snacks"] = {
        is_available = function()
          return false
        end,
      }
      owned.wait_for_exec = function(id)
        table.insert(events, "wait_for_exec " .. id)
      end
    end)

    after_each(function()
      package.loaded["claudecode.terminal.snacks"] = nil
    end)

    it("waits for the child to run exec before it stops the job", function()
      assert.is_true(owned.stop_other(owned.SNACKS_MARK, "snacks"))

      assert.are.same({ "wait_for_exec 7", "jobstop", "delete" }, events)
    end)
  end)
end)

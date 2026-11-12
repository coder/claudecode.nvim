-- Real-Neovim guards for the JIT while a tool's coroutine runs. A LuaJIT older than September 2023 (bundled by Neovim
-- 0.8 and 0.9) has a bug (LuaJIT issue #1066): when a Neovim API call raises inside a coroutine because a handler it
-- ran raised, LuaJIT keeps pointing at the main Lua thread, and the next exit from a compiled trace corrupts the stack
-- of that thread. Neovim then aborts or crashes. The first case reads the state of the JIT, so its result does not
-- depend on a failure rate. The second case keeps a JIT that the user turned off off. The third case raises in
-- handlers under an eager JIT, as diff_failed_setup_guards_spec.lua does, for setups that succeed. Under busted's mock
-- vim this is pending; scripts/run_integration_tests_individually.sh runs it in Neovim, including CI's oldest supported
-- version.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff and the JIT of a LuaJIT with issue 1066", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openDiff and the JIT of a LuaJIT with issue 1066", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local tab_name = "✻ [Claude Code] proposal ⧉"
  local group = "diff_tool_coroutine_jit_spec"
  -- Rolling releases of LuaJIT 2.1 are numbered with the unix time of their commit. 1695261248 is the commit that fixed
  -- the bug. The plugin makes the same decision, and this spec does not read it from the plugin.
  local affected = jit ~= nil and (tonumber(jit.version:match("^LuaJIT 2%.1%.(%d+)$")) or 0) < 1695261248
  local jit_was_on, real_resume
  local dir, path

  local function has_compiled_trace()
    for number = 1, 100 do
      if require("jit.util").traceinfo(number) then
        return true
      end
    end
    return false
  end

  local function compile_a_trace()
    local sum = 0
    for index = 1, 1000 do
      sum = sum + index % 7
    end
    return sum
  end

  local function observe()
    return { on = (jit.status()), trace = has_compiled_trace() }
  end

  local function assert_the_guard_state(observed, what)
    assert.equal(not affected, observed.on, what .. ": the JIT is on unless the LuaJIT has the bug")
    if affected then
      assert.is_false(observed.trace, what .. ": no compiled trace exists")
    end
  end

  local function open_diff()
    local call = tools.handle_invoke({ id = "tool_coroutine_jit_spec" }, {
      name = "openDiff",
      arguments = {
        old_file_path = path,
        new_file_path = path,
        new_file_contents = "alpha\nBETA\n",
        tab_name = tab_name,
      },
    })
    if call._deferred then
      _G.claude_deferred_responses[tostring(call.coroutine)] = function() end
    end
    return call
  end

  local function accept_the_diff()
    vim.api.nvim_set_current_win(diff._get_active_diffs()[tab_name].new_window)
    vim.cmd("write")
  end

  local function reset()
    pcall(vim.api.nvim_del_augroup_by_name, group)
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
  end

  before_each(function()
    vim.o.columns, vim.o.lines = 160, 40
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    path = dir .. "/a.txt"
    vim.fn.writefile({ "alpha", "beta" }, path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_create_augroup(group, { clear = true })
    diff.setup(vim.deepcopy(require("claudecode.config").defaults))
    tools.register_all()
    _G.claude_deferred_responses = {}
    jit_was_on, real_resume = jit.status(), coroutine.resume
  end)

  after_each(function()
    coroutine.resume = real_resume -- luacheck: ignore 122
    reset()
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
    jit.opt.start("hotloop=56", "hotexit=10", "tryside=4") -- LuaJIT's defaults
    if jit_was_on then
      jit.on()
    end
  end)

  it("runs the coroutine of a tool with the JIT off and no compiled trace, and turns the JIT on again", function()
    compile_a_trace()
    assert.is_true(jit.status(), "the JIT is on before the call")
    assert.is_true(has_compiled_trace(), "a compiled trace exists before the call")
    local in_handlers, in_resumes = {}, {}
    vim.api.nvim_create_autocmd({ "WinNew", "WinLeave", "BufWinEnter" }, {
      group = group,
      callback = function()
        table.insert(in_handlers, observe())
      end,
    })
    coroutine.resume = function(co, ...) -- luacheck: ignore 122
      in_resumes[co] = in_resumes[co] or {}
      table.insert(in_resumes[co], observe())
      return real_resume(co, ...)
    end

    local call = open_diff()
    assert.is_true(call._deferred, "openDiff waits for the user")
    assert.is_true(jit.status(), "the JIT is on again after the call")
    accept_the_diff()
    assert.is_true(jit.status(), "the JIT is on again after the answer")

    assert.is_true(#in_handlers > 0, "a handler ran while the diff opened")
    for _, observed in ipairs(in_handlers) do
      assert_the_guard_state(observed, "in a handler")
    end
    assert.equal(2, #in_resumes[call.coroutine], "the coroutine resumes at the call and at the answer")
    for _, observed in ipairs(in_resumes[call.coroutine]) do
      assert_the_guard_state(observed, "at a resume")
    end
  end)

  it("keeps a JIT that was off off", function()
    jit.off()
    local seen = {}
    vim.api.nvim_create_autocmd("WinNew", {
      group = group,
      callback = function()
        table.insert(seen, observe())
      end,
    })

    local call = open_diff()
    assert.is_true(call._deferred, "openDiff waits for the user")
    assert.is_false(jit.status(), "the JIT is off after the call")
    accept_the_diff()
    assert.is_false(jit.status(), "the JIT is off after the answer")

    assert.is_true(#seen > 0, "a handler ran while the diff opened")
    for _, observed in ipairs(seen) do
      assert.is_false(observed.on)
      if affected then
        assert.is_false(observed.trace)
      end
    end
  end)

  -- A second openDiff of the same tab first closes the windows of the first diff, in its own coroutine. A handler that
  -- raises then is caught by a pcall of the plugin, and both calls open a diff. Without the guard this case does not
  -- abort Neovim (the cases of diff_failed_setup_guards_spec.lua do), so it shows no bug. It shows that the guard
  -- leaves the answers of openDiff as they are.
  it("keeps Neovim running when handlers raise on repeated setups that succeed under an eager JIT", function()
    jit.opt.start("hotloop=1", "hotexit=1", "tryside=1")
    local raised = 0
    for _ = 1, 6 do
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      vim.api.nvim_create_augroup(group, { clear = true })
      vim.api.nvim_create_autocmd({ "WinClosed", "BufWinLeave", "BufHidden" }, {
        group = group,
        callback = function()
          raised = raised + 1
          error("a handler of the user raised")
        end,
      })
      assert.is_true(open_diff()._deferred, "the first openDiff waits for the user")
      assert.is_true(open_diff()._deferred, "the second openDiff replaces the first and waits for the user")
      reset()
    end
    assert.is_true(raised > 0, "a handler raised")
  end)
end)

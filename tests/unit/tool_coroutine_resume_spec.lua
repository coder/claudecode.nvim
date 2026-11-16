require("tests.busted_setup")
local diff = require("claudecode.diff")
local temp_dir = require("tests.helpers.temp_dir")
local tools = require("claudecode.tools.init")
local utils = require("claudecode.utils")

-- Every resume of a tool's coroutine goes through utils.resume_tool_coroutine, which keeps the JIT off while the
-- coroutine runs on a LuaJIT with issue 1066.
describe("resuming the coroutine of a tool", function()
  local real_resume, resumes, dir

  before_each(function()
    real_resume, resumes, dir = utils.resume_tool_coroutine, {}, temp_dir.new()
    utils.resume_tool_coroutine = function(co, ...)
      table.insert(resumes, { co = co, first = (...) })
      return real_resume(co, ...)
    end
  end)

  after_each(function()
    utils.resume_tool_coroutine = real_resume
    tools.tools.waiting_probe = nil
    diff._cleanup_all_active_diffs("test cleanup")
    temp_dir.remove(dir)
  end)

  it("goes through the helper when handle_invoke runs the tool", function()
    tools.tools.waiting_probe = {
      handler = function()
        coroutine.yield()
      end,
      requires_coroutine = true,
    }

    local call = tools.handle_invoke(nil, { name = "waiting_probe" })

    assert.is_true(call._deferred)
    assert.same({ { co = call.coroutine } }, resumes)
  end)

  it("goes through the helper when a blocking diff is answered", function()
    local file = dir .. "/resume.txt"
    local handle = assert(io.open(file, "w"))
    handle:write("line 1\n")
    handle:close()
    local co = coroutine.create(function()
      diff.open_diff_blocking(file, file, "line 1\nline 2\n", "resume tab", "client")
    end)
    assert.is_true(coroutine.resume(co))
    assert.equal("suspended", coroutine.status(co))
    resumes = {}

    diff.close_all_diffs("test")

    assert.equal(1, #resumes)
    assert.equal(co, resumes[1].co)
    assert.equal("DIFF_REJECTED", resumes[1].first.content[1].text)
  end)
end)

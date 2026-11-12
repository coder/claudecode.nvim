require("tests.busted_setup")

-- The check for LuaJIT issue 1066 runs when the module loads, so each case loads the module again under a stubbed
-- global `jit` that records what the helper does to the JIT.
describe("claudecode.utils.resume_tool_coroutine", function()
  local real_jit, real_utils
  local calls, jit_on, jit_on_during_resume

  local function pack(...)
    return { n = select("#", ...), ... }
  end

  local function load_utils(version, on_before)
    calls, jit_on = {}, on_before
    local stub = {
      version = version,
      status = function()
        return jit_on
      end,
      off = function()
        table.insert(calls, "off")
        jit_on = false
      end,
      flush = function()
        table.insert(calls, "flush")
      end,
      on = function()
        table.insert(calls, "on")
        jit_on = true
      end,
    }
    _G.jit = stub
    package.loaded["claudecode.utils"] = nil
    return require("claudecode.utils")
  end

  -- A tool's coroutine: it records that it ran and whether the JIT was on then, then gives back its arguments.
  local function create_coroutine()
    return coroutine.create(function(...)
      table.insert(calls, "resume")
      jit_on_during_resume = jit and jit.status()
      return ...
    end)
  end

  before_each(function()
    real_jit, real_utils = _G.jit, package.loaded["claudecode.utils"]
    jit_on_during_resume = nil
  end)

  after_each(function()
    _G.jit, package.loaded["claudecode.utils"] = real_jit, real_utils
  end)

  it("resumes with a plain coroutine.resume when there is no jit global", function()
    _G.jit = nil
    package.loaded["claudecode.utils"] = nil
    calls = {}
    local utils = require("claudecode.utils")

    assert.same({ true, "a", "b" }, { utils.resume_tool_coroutine(create_coroutine(), "a", "b") })
    assert.same({ "resume" }, calls)
  end)

  for _, version in ipairs({ "LuaJIT 2.1.1695261248", "LuaJIT 2.1.1774638290", "LuaJIT 2.1.9999999999" }) do
    it("leaves the JIT alone on " .. version, function()
      local utils = load_utils(version, true)

      assert.same({ true, "a" }, { utils.resume_tool_coroutine(create_coroutine(), "a") })
      assert.same({ "resume" }, calls)
      assert.is_true(jit_on_during_resume)
      assert.is_true(jit_on)
    end)
  end

  for _, version in ipairs({ "LuaJIT 2.1.0-beta3", "LuaJIT 2.1.1692716794", "LuaJIT 2.1.1695261247" }) do
    it("turns the JIT off, flushes its traces and turns it on again on " .. version, function()
      local utils = load_utils(version, true)

      assert.same({ true, "a" }, { utils.resume_tool_coroutine(create_coroutine(), "a") })
      assert.same({ "off", "flush", "resume", "on" }, calls)
      assert.is_false(jit_on_during_resume)
      assert.is_true(jit_on)
    end)
  end

  for _, version in ipairs({ "LuaJIT 2.0.5", "LuaJIT", "unknown", "LuaJIT 2.1.1695261248-custom", "" }) do
    it("treats the version string '" .. version .. "' as affected", function()
      local utils = load_utils(version, true)

      assert.same({ true }, { utils.resume_tool_coroutine(create_coroutine()) })
      assert.same({ "off", "flush", "resume", "on" }, calls)
      assert.is_false(jit_on_during_resume)
    end)
  end

  for _, case in ipairs({ { "no version" }, { "a number as the version", 42 }, { "a table as the version", {} } }) do
    it("treats " .. case[1] .. " as affected", function()
      local utils = load_utils(case[2], true)

      assert.same({ true }, { utils.resume_tool_coroutine(create_coroutine()) })
      assert.same({ "off", "flush", "resume", "on" }, calls)
      assert.is_false(jit_on_during_resume)
    end)
  end

  it("flushes the traces but keeps the JIT off when the JIT was off before", function()
    local utils = load_utils("LuaJIT 2.1.0-beta3", false)

    assert.same({ true }, { utils.resume_tool_coroutine(create_coroutine()) })
    assert.same({ "off", "flush", "resume" }, calls)
    assert.is_false(jit_on_during_resume)
    assert.is_false(jit_on)
  end)

  it("gives back what the coroutine returns and takes, trailing nils included", function()
    for _, version in ipairs({ "LuaJIT 2.1.0-beta3", "LuaJIT 2.1.1774638290" }) do
      local utils = load_utils(version, true)

      local echoed = pack(utils.resume_tool_coroutine(create_coroutine(), 1, nil, 3, nil))
      assert.same({ n = 5, true, 1, nil, 3 }, echoed, version)

      local nothing = pack(utils.resume_tool_coroutine(coroutine.create(function() end)))
      assert.same({ n = 1, true }, nothing, version)
    end
  end)

  it("turns the JIT on again when the coroutine raises, and gives back the error", function()
    local utils = load_utils("LuaJIT 2.1.0-beta3", true)

    local success, err = utils.resume_tool_coroutine(coroutine.create(function()
      error("a tool raised", 0)
    end))

    assert.is_false(success)
    assert.equal("a tool raised", err)
    assert.same({ "off", "flush", "on" }, calls)
    assert.is_true(jit_on)
  end)

  it("guards each resume of a coroutine that yields", function()
    local utils = load_utils("LuaJIT 2.1.0-beta3", true)
    local co = coroutine.create(function()
      local answer = coroutine.yield("waiting")
      return answer
    end)

    assert.same({ true, "waiting" }, { utils.resume_tool_coroutine(co) })
    assert.is_true(jit_on, "the JIT is on again while the coroutine waits")
    assert.same({ true, "accepted" }, { utils.resume_tool_coroutine(co, "accepted") })
    assert.same({ "off", "flush", "on", "off", "flush", "on" }, calls)
  end)
end)

require("tests.busted_setup")

describe("tests.mocks.vim wait", function()
  local mock_vim = require("tests.mocks.vim")
  local stub = require("luassert.stub")
  local execute_stub, popen_stub

  before_each(function()
    execute_stub = stub(os, "execute")
    popen_stub = stub(io, "popen")
  end)

  after_each(function()
    execute_stub:revert()
    popen_stub:revert()
  end)

  it("returns true at once when the condition already holds", function()
    local polls = 0

    local ok = mock_vim.wait(1000, function()
      polls = polls + 1
      return true
    end, 10)

    assert.is_true(ok)
    assert.are.equal(1, polls)
  end)

  it("returns true when the condition holds on a later poll", function()
    local polls = 0

    local ok = mock_vim.wait(1000, function()
      polls = polls + 1
      return polls == 5
    end, 10)

    assert.is_true(ok)
    assert.are.equal(5, polls)
  end)

  it("returns false after timeout / interval + 1 polls when the condition never holds", function()
    local polls = 0

    local ok = mock_vim.wait(1000, function()
      polls = polls + 1
      return false
    end, 10)

    assert.is_false(ok)
    assert.are.equal(101, polls)
  end)

  it("defaults to a 1000 ms timeout and a 10 ms interval", function()
    local polls = 0

    mock_vim.wait(nil, function()
      polls = polls + 1
      return false
    end)

    assert.are.equal(101, polls)
  end)

  it("returns false without a condition", function()
    assert.is_false(mock_vim.wait(50))
  end)

  it("does not spawn a process while it waits", function()
    mock_vim.wait(1000, function()
      return false
    end, 10)

    assert.stub(execute_stub).was_not.called()
    assert.stub(popen_stub).was_not.called()
  end)

  it("rejects a condition that is not a function", function()
    assert.has_error(function()
      mock_vim.wait(100, true)
    end)
  end)
end)

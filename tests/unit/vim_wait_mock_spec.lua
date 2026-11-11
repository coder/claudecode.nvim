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

  it("rounds the poll count down when the interval does not divide the timeout", function()
    local polls = 0

    mock_vim.wait(105, function()
      polls = polls + 1
      return false
    end, 10)

    assert.are.equal(11, polls)
  end)

  it("defaults to a 1000 ms timeout and a 10 ms interval", function()
    local polls = 0

    mock_vim.wait(nil, function()
      polls = polls + 1
      return false
    end)

    assert.are.equal(101, polls)
  end)

  it("calls a table that has a __call function, as Neovim's vim.wait does", function()
    local polls = 0
    local condition = setmetatable({}, {
      __call = function()
        polls = polls + 1
        return polls == 3
      end,
    })

    assert.is_true(mock_vim.wait(1000, condition, 10))
    assert.are.equal(3, polls)
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

  it("treats an interval below 1 as 1", function()
    local function never_true_until(limit)
      local counter = { polls = 0 }
      function counter.condition()
        counter.polls = counter.polls + 1
        assert(counter.polls <= limit, "polled more than " .. limit .. " times")
        return false
      end
      return counter
    end

    local zero = never_true_until(1000)
    assert.is_false(mock_vim.wait(100, zero.condition, 0))
    assert.are.equal(101, zero.polls)

    local negative = never_true_until(1000)
    assert.is_false(mock_vim.wait(100, negative.condition, -5))
    assert.are.equal(101, negative.polls)
  end)

  describe("argument checks", function()
    local function wait_error(...)
      local ok, err = pcall(mock_vim.wait, ...)
      assert.is_false(ok)
      return tostring(err)
    end

    it("rejects a condition that is not callable", function()
      assert.is_truthy(wait_error(100, false):find("vim.wait: condition must be callable", 1, true))
    end)

    it("rejects a table without a __call function", function()
      local message = "vim.wait: condition must be callable"

      assert.is_truthy(wait_error(100, {}):find(message, 1, true))
      assert.is_truthy(wait_error(100, setmetatable({}, { __call = {} })):find(message, 1, true))
    end)

    it("rejects a timeout that is not a number", function()
      local err = wait_error("100", function()
        return true
      end)

      assert.is_truthy(err:find("vim.wait: timeout must be a number", 1, true))
    end)

    it("rejects an interval that is not a number", function()
      local err = wait_error(100, function()
        return true
      end, "10")

      assert.is_truthy(err:find("vim.wait: interval must be a number", 1, true))
    end)
  end)
end)

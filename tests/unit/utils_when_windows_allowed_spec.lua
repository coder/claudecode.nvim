require("tests.busted_setup")

describe("claudecode.utils.when_windows_allowed", function()
  local utils = require("claudecode.utils")
  local saved = {}
  local refusal, timers

  before_each(function()
    saved.set_current_win, saved.defer_fn = vim.api.nvim_set_current_win, vim.defer_fn
    refusal, timers = nil, {}
    vim.api.nvim_set_current_win = function(win)
      if refusal then
        error(refusal)
      end
      saved.set_current_win(win)
    end
    vim.defer_fn = function(fn, timeout)
      table.insert(timers, { fn = fn, timeout = timeout })
    end
  end)

  after_each(function()
    vim.api.nvim_set_current_win, vim.defer_fn = saved.set_current_win, saved.defer_fn
  end)

  local function fire_timers()
    local due = timers
    timers = {}
    for _, timer in ipairs(due) do
      timer.fn()
    end
  end

  it("runs the function at once when Neovim allows window changes, and keeps the current window", function()
    local window = vim.api.nvim_get_current_win()
    local runs = 0

    utils.when_windows_allowed(function()
      runs = runs + 1
    end)

    assert.are.equal(1, runs)
    assert.are.same({}, timers)
    assert.are.equal(window, vim.api.nvim_get_current_win())
  end)

  it("holds the function while Neovim refuses window changes and runs it once when it allows them", function()
    local runs = 0
    refusal = "E11: Invalid in command-line window; <CR> executes, CTRL-C quits"

    utils.when_windows_allowed(function()
      runs = runs + 1
    end)
    assert.are.equal(0, runs)
    assert.are.equal(1, #timers)
    assert.are.equal(50, timers[1].timeout)

    refusal = "E565: Not allowed to change text or change window"
    fire_timers()
    assert.are.equal(0, runs)
    assert.are.equal(1, #timers)

    refusal = nil
    fire_timers()
    assert.are.equal(1, runs)
    assert.are.same({}, timers)
  end)

  it("keeps one retry timer for all the functions it holds, and runs each once", function()
    local runs = { 0, 0, 0 }
    refusal = "E565: Not allowed to change text or change window"

    for i = 1, 3 do
      utils.when_windows_allowed(function()
        runs[i] = runs[i] + 1
      end)
    end
    assert.are.equal(1, #timers)
    fire_timers()
    assert.are.equal(1, #timers)

    refusal = nil
    fire_timers()
    assert.are.same({ 1, 1, 1 }, runs)
    assert.are.same({}, timers)
  end)

  it("runs every other held function when one of them raises", function()
    local scheduled, schedule = {}, vim.schedule
    vim.schedule = function(fn)
      table.insert(scheduled, fn)
    end
    local ran = false
    refusal = "E11: Invalid in command-line window; <CR> executes, CTRL-C quits"
    utils.when_windows_allowed(function()
      error("a held function raised")
    end)
    utils.when_windows_allowed(function()
      ran = true
    end)

    refusal = nil
    fire_timers()
    vim.schedule = schedule
    local errors = {}
    for _, fn in ipairs(scheduled) do
      local ok, err = pcall(fn)
      if not ok then
        table.insert(errors, err)
      end
    end

    assert.are.equal(1, #errors)
    assert.is_true(ran)
  end)
end)

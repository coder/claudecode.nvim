require("tests.busted_setup")

-- Fakes only what `utils.win_set_buf_in_split` reads and calls, and logs what it does in order. The behavior in a real
-- Neovim (where the terminal lands, the events that Neovim fires) is in tests/integration/terminal_placement_spec.lua.
describe("claudecode.utils.win_set_buf_in_split", function()
  local utils = require("claudecode.utils")

  local SPLIT, OTHER, FAR, OLD, TERMINAL = 1001, 1002, 1003, 7, 8
  local saved
  local state
  local log

  local function stub(parent, name, fn)
    saved[#saved + 1] = { parent = parent, name = name, value = parent[name] }
    parent[name] = fn
  end

  before_each(function()
    saved = {}
    log = {}
    state = {
      current = SPLIT,
      previous = 0,
      win_bufs = { [SPLIT] = OLD, [OTHER] = OLD, [FAR] = OLD },
      tabs = { [SPLIT] = 1, [OTHER] = 1, [FAR] = 1 },
      floats = {},
      invalid = {},
      enter_events = true,
      probes = {},
      eventignore_seen = {},
    }
    saved[#saved + 1] = { parent = vim.o, name = "eventignore", value = vim.o.eventignore }
    vim.o.eventignore = ""

    stub(vim.api, "nvim_get_current_win", function()
      return state.current
    end)
    stub(vim.api, "nvim_get_current_buf", function()
      return state.win_bufs[state.current]
    end)
    stub(vim.api, "nvim_win_get_buf", function(win)
      return state.win_bufs[win]
    end)
    stub(vim.api, "nvim_win_is_valid", function(win)
      return not state.invalid[win]
    end)
    stub(vim.api, "nvim_win_get_tabpage", function(win)
      return state.tabs[win]
    end)
    stub(vim.api, "nvim_win_get_config", function(win)
      return { relative = state.floats[win] and "editor" or "" }
    end)
    stub(vim.fn, "win_findbuf", function(buf)
      local wins = {}
      for _, win in ipairs({ SPLIT, OTHER, FAR }) do
        if state.win_bufs[win] == buf and not state.invalid[win] then
          table.insert(wins, win)
        end
      end
      return wins
    end)
    stub(vim.fn, "winnr", function(arg)
      assert.equal("#", arg)
      return state.previous
    end)
    stub(vim.fn, "win_getid", function(nr)
      return nr
    end)
    stub(vim.api, "nvim_win_set_buf", function(win, buf)
      table.insert(log, string.format("plain set_buf %d %d", win, buf))
      state.win_bufs[win] = buf
    end)
    stub(vim.api, "nvim_create_augroup", function(name)
      assert.is_truthy(name:match("^claudecode_placement_probe_%d+$"), name)
      table.insert(log, "create_group")
      return 77
    end)
    stub(vim.api, "nvim_create_autocmd", function(events, opts)
      assert.same({ "WinLeave", "BufLeave", "WinEnter", "BufEnter" }, events)
      assert.equal(77, opts.group)
      state.probes = { opts.callback }
    end)
    stub(vim.api, "nvim_del_augroup_by_id", function(id)
      table.insert(log, "del_group " .. id)
      state.probes = {}
    end)
    stub(vim.api, "nvim_set_current_win", function(win)
      table.insert(log, string.format("enter %d eventignore=%s", win, vim.o.eventignore))
      table.insert(state.eventignore_seen, vim.o.eventignore)
      state.current = win
      if state.raise_on_enter then
        if state.on_enter then
          state.on_enter()
        end
        error("Failed to switch to window " .. win, 0)
      end
      if state.enter_events then
        for _, probe in ipairs(state.probes) do
          probe()
        end
      end
      if state.on_enter then
        state.on_enter()
      end
    end)
    stub(vim.api, "nvim_win_call", function(win, fn)
      local before = state.current
      state.current = win
      fn()
      state.current = before
    end)
    stub(vim.api, "nvim_exec_autocmds", function(event, opts)
      table.insert(
        log,
        string.format("%s@%d in %d eventignore=%s", event, opts.buffer, state.current, vim.o.eventignore)
      )
      table.insert(state.eventignore_seen, vim.o.eventignore)
    end)
    stub(vim, "cmd", function(command)
      local set_win, set_buf = command:match("^noautocmd call nvim_win_set_buf%((%d+), (%d+)%)$")
      if set_win then
        if state.raise_on_swap then
          error("E5555: no", 0)
        end
        table.insert(log, string.format("noautocmd set_buf %s %s", set_win, set_buf))
        state.win_bufs[tonumber(set_win)] = tonumber(set_buf)
        return
      end
      local target = command:match("^noautocmd call nvim_set_current_win%((%d+)%)$")
      assert.is_not_nil(target, "unexpected command: " .. command)
      table.insert(log, "noautocmd enter " .. target)
      state.current = tonumber(target)
    end)
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      local entry = saved[i]
      entry.parent[entry.name] = entry.value
    end
  end)

  it(
    "swaps with no autocmd, goes back to the other window silently, enters the split, and fires BufWinEnter",
    function()
      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.same({
        "noautocmd set_buf 1001 8",
        "noautocmd enter 1002",
        "create_group",
        "enter 1001 eventignore=",
        "del_group 77",
        "BufWinEnter@8 in 1001 eventignore=",
      }, log)
      assert.equal(SPLIT, state.current)
    end
  )

  it("fires no BufLeave, BufWinLeave, BufHidden or BufUnload itself", function()
    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    for _, line in ipairs(log) do
      assert.is_nil(line:find("Leave", 1, true), line)
      assert.is_nil(line:find("Hidden", 1, true), line)
      assert.is_nil(line:find("Unload", 1, true), line)
    end
  end)

  it(
    "fires BufWinEnter for the buffer that is in the split after the enter, which an autocmd can have swapped in",
    function()
      state.on_enter = function()
        state.win_bufs[SPLIT] = 99
      end

      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.equal("BufWinEnter@99 in 1001 eventignore=", log[#log])
    end
  )

  it("fires no BufWinEnter when Neovim ran no enter event, as inside a non-nested autocmd", function()
    state.enter_events = false

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.same({
      "noautocmd set_buf 1001 8",
      "noautocmd enter 1002",
      "create_group",
      "enter 1001 eventignore=",
      "del_group 77",
    }, log)
  end)

  it("fires no BufWinEnter when an autocmd of the enter closed the split", function()
    state.on_enter = function()
      state.invalid[SPLIT] = true
    end

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.is_nil(log[#log]:find("BufWinEnter", 1, true))
  end)

  it("puts the cursor back in the split when an autocmd of the enter entered another window, silently", function()
    state.on_enter = function()
      state.current = FAR
    end

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.same({
      "noautocmd set_buf 1001 8",
      "noautocmd enter 1002",
      "create_group",
      "enter 1001 eventignore=",
      "del_group 77",
      "noautocmd enter 1001",
      "BufWinEnter@8 in 1001 eventignore=",
    }, log)
    assert.equal(SPLIT, state.current)
  end)

  it("passes on no error when an autocmd of the enter entered another window and Neovim refused the move", function()
    state.raise_on_enter = true
    state.on_enter = function()
      state.current = FAR
    end

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.equal("noautocmd enter 1001", log[#log])
    assert.equal(SPLIT, state.current)
  end)

  it(
    "passes on no error and fires no BufWinEnter when an autocmd of the enter closed the split and Neovim refused",
    function()
      state.raise_on_enter = true
      state.on_enter = function()
        state.invalid[SPLIT] = true
        state.current = FAR
      end

      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      for _, line in ipairs(log) do
        assert.is_nil(line:find("BufWinEnter", 1, true), line)
      end
    end
  )

  describe("goes back to", function()
    it("the previous window, which is the one the split was made from", function()
      state.previous = FAR

      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.equal("noautocmd enter 1003", log[2])
    end)

    it("the first other window of the tab that shows the buffer, without a previous window", function()
      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.equal("noautocmd enter 1002", log[2])
    end)

    it("a window of the tab, not one that shows the buffer in another tab or in a float", function()
      state.tabs[OTHER] = 2
      state.floats[FAR] = true
      state.win_bufs[FAR] = OLD
      state.tabs[FAR] = 1

      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.same({ "plain set_buf 1001 8" }, log)
    end)
  end)

  describe("does what a plain swap does", function()
    it("when no other window shows the buffer", function()
      state.win_bufs[OTHER] = 99
      state.win_bufs[FAR] = 99

      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.same({ "plain set_buf 1001 8" }, log)
    end)

    it("when the split already shows the buffer", function()
      state.win_bufs[SPLIT] = TERMINAL

      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.same({ "plain set_buf 1001 8" }, log)
    end)

    it("when the split is not the current window", function()
      state.current = OTHER

      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.same({ "plain set_buf 1001 8" }, log)
    end)
  end)

  describe("with ignore_bufenter", function()
    it("keeps BufEnter in 'eventignore' for the whole call and gives it back", function()
      vim.o.eventignore = "CursorHold"

      utils.win_set_buf_in_split(SPLIT, TERMINAL, { ignore_bufenter = true })

      assert.is_true(#state.eventignore_seen > 0)
      for _, seen in ipairs(state.eventignore_seen) do
        assert.equal("CursorHold,BufEnter", seen)
      end
      assert.equal("CursorHold", vim.o.eventignore)
    end)

    it("drops a -BufEnter entry for the call, because it would beat the later BufEnter", function()
      vim.o.eventignore = "all,-bufenter,CursorHold"

      utils.win_set_buf_in_split(SPLIT, TERMINAL, { ignore_bufenter = true })

      assert.equal("all,CursorHold,BufEnter", state.eventignore_seen[1])
      assert.equal("all,-bufenter,CursorHold", vim.o.eventignore)
    end)

    it("ignores BufEnter in a plain swap too", function()
      state.current = OTHER
      vim.api.nvim_win_set_buf = function(win, buf)
        table.insert(log, string.format("plain set_buf %d %d eventignore=%s", win, buf, vim.o.eventignore))
      end

      utils.win_set_buf_in_split(SPLIT, TERMINAL, { ignore_bufenter = true })

      assert.same({ "plain set_buf 1001 8 eventignore=BufEnter" }, log)
      assert.equal("", vim.o.eventignore)
    end)

    it("gives 'eventignore' back and raises the same error when the swap fails", function()
      vim.o.eventignore = "CursorHold"
      state.raise_on_swap = true

      local ok, err = pcall(utils.win_set_buf_in_split, SPLIT, TERMINAL, { ignore_bufenter = true })

      assert.is_false(ok)
      assert.equal("E5555: no", err)
      assert.equal("CursorHold", vim.o.eventignore)
    end)
  end)

  it("deletes its probe group and raises the same error when the enter fails with the cursor in the split", function()
    state.raise_on_enter = true
    state.on_enter = function()
      state.current = SPLIT
    end

    local ok, err = pcall(utils.win_set_buf_in_split, SPLIT, TERMINAL)

    assert.is_false(ok)
    assert.equal("Failed to switch to window 1001", err)
    assert.equal("del_group 77", log[#log])
  end)

  it("leaves 'eventignore' alone without ignore_bufenter", function()
    vim.o.eventignore = "CursorHold"

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    for _, seen in ipairs(state.eventignore_seen) do
      assert.equal("CursorHold", seen)
    end
  end)
end)

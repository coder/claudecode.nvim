require("tests.busted_setup")

-- Fakes only what `utils.win_set_buf_in_split` reads and calls, and logs what it does in order. The behavior in a real
-- Neovim (where the terminal lands, the events it fires) is in tests/integration/terminal_placement_spec.lua.
describe("claudecode.utils.win_set_buf_in_split", function()
  local utils = require("claudecode.utils")

  local SPLIT, OLD, TERMINAL, OTHER_WIN = 1001, 7, 8, 1002
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
      win_bufs = { [SPLIT] = OLD, [OTHER_WIN] = OLD },
      shown = { [OLD] = { SPLIT, OTHER_WIN }, [TERMINAL] = {} },
      bufhidden = {},
      invalid = {},
      on = {},
      eventignore_seen = {},
    }
    saved[#saved + 1] = { parent = vim.o, name = "eventignore", value = vim.o.eventignore }
    saved[#saved + 1] = { parent = vim.o, name = "hidden", value = vim.o.hidden }
    vim.o.eventignore = ""
    vim.o.hidden = true

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
    stub(vim.api, "nvim_buf_get_option", function(buf, name)
      assert.equal("bufhidden", name)
      return state.bufhidden[buf] or ""
    end)
    stub(vim.fn, "win_findbuf", function(buf)
      return state.shown[buf] or {}
    end)
    stub(vim.api, "nvim_win_set_buf", function(win, buf)
      table.insert(log, string.format("plain set_buf %d %d", win, buf))
      state.win_bufs[win] = buf
    end)
    stub(vim.api, "nvim_exec_autocmds", function(event, opts)
      table.insert(log, string.format("%s@%d eventignore=%s", event, opts.buffer, vim.o.eventignore))
      table.insert(state.eventignore_seen, vim.o.eventignore)
      if state.on[event] then
        state.on[event]()
      end
    end)
    stub(vim, "cmd", function(command)
      local set_buf_win, set_buf_buf = command:match("^noautocmd call nvim_win_set_buf%((%d+), (%d+)%)$")
      if set_buf_win then
        if state.raise then
          error("E5555: no", 0)
        end
        table.insert(log, string.format("noautocmd set_buf %s %s", set_buf_win, set_buf_buf))
        state.win_bufs[tonumber(set_buf_win)] = tonumber(set_buf_buf)
        return
      end
      local target = command:match("^noautocmd call nvim_set_current_win%((%d+)%)$")
      assert.is_not_nil(target, "unexpected command: " .. command)
      table.insert(log, "noautocmd set_current_win " .. target)
      state.current = tonumber(target)
    end)
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      local entry = saved[i]
      entry.parent[entry.name] = entry.value
    end
  end)

  it("runs the events of the buffer that leaves before the swap, and BufEnter and BufWinEnter after it", function()
    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.same({
      "BufLeave@7 eventignore=",
      "noautocmd set_buf 1001 8",
      "BufEnter@8 eventignore=",
      "BufWinEnter@8 eventignore=",
    }, log)
  end)

  it("also fires BufWinLeave and BufHidden when the split was the last window of the buffer", function()
    state.shown[OLD] = { SPLIT }
    state.win_bufs[OTHER_WIN] = nil

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.same({
      "BufLeave@7 eventignore=",
      "BufWinLeave@7 eventignore=",
      "BufHidden@7 eventignore=",
      "noautocmd set_buf 1001 8",
      "BufEnter@8 eventignore=",
      "BufWinEnter@8 eventignore=",
    }, log)
  end)

  it("fires BufWinEnter for the buffer that is current after BufEnter, which an autocmd can have swapped in", function()
    state.on.BufEnter = function()
      state.win_bufs[SPLIT] = 99
    end

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.equal("BufWinEnter@99 eventignore=", log[#log])
  end)

  it("moves the cursor back to the split when a BufLeave autocmd entered another window", function()
    state.on.BufLeave = function()
      state.current = OTHER_WIN
    end

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.same({
      "BufLeave@7 eventignore=",
      "noautocmd set_current_win 1001",
      "noautocmd set_buf 1001 8",
      "BufEnter@8 eventignore=",
      "BufWinEnter@8 eventignore=",
    }, log)
    assert.equal(SPLIT, state.current)
    assert.equal(TERMINAL, state.win_bufs[SPLIT])
    assert.equal(OLD, state.win_bufs[OTHER_WIN])
  end)

  it("fires no event, and swaps nothing, when a BufLeave autocmd closed the split", function()
    state.on.BufLeave = function()
      state.invalid[SPLIT] = true
    end

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.same({ "BufLeave@7 eventignore=" }, log)
  end)

  it("fires no BufWinLeave or BufHidden when the split was the last window and an autocmd closed it", function()
    -- The close fired them already.
    state.shown[OLD] = { SPLIT }
    state.on.BufLeave = function()
      state.invalid[SPLIT] = true
    end

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.same({ "BufLeave@7 eventignore=" }, log)
  end)

  describe("does what a plain swap does", function()
    it("when the split already shows the buffer", function()
      state.win_bufs[SPLIT] = TERMINAL

      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.same({ "plain set_buf 1001 8" }, log)
    end)

    it("when the split is not the current window", function()
      state.current = OTHER_WIN

      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.same({ "plain set_buf 1001 8" }, log)
    end)

    for _, case in ipairs({
      { name = "'bufhidden' is empty and 'hidden' is off", bufhidden = "", hidden = false },
      { name = "'bufhidden' is unload", bufhidden = "unload", hidden = true },
      { name = "'bufhidden' is delete", bufhidden = "delete", hidden = true },
      { name = "'bufhidden' is wipe", bufhidden = "wipe", hidden = true },
    }) do
      it("when the swap would unload the last window's buffer, as " .. case.name, function()
        state.shown[OLD] = { SPLIT }
        state.bufhidden[OLD] = case.bufhidden
        vim.o.hidden = case.hidden

        utils.win_set_buf_in_split(SPLIT, TERMINAL)

        assert.same({ "plain set_buf 1001 8" }, log)
      end)
    end

    for _, case in ipairs({
      { name = "'bufhidden' is empty and 'hidden' is on", bufhidden = "", hidden = true },
      { name = "'bufhidden' is hide and 'hidden' is off", bufhidden = "hide", hidden = false },
    }) do
      it("only after the events of the leaving buffer when the buffer stays loaded, as " .. case.name, function()
        state.shown[OLD] = { SPLIT }
        state.bufhidden[OLD] = case.bufhidden
        vim.o.hidden = case.hidden

        utils.win_set_buf_in_split(SPLIT, TERMINAL)

        assert.equal("BufLeave@7 eventignore=", log[1])
        assert.equal("noautocmd set_buf 1001 8", log[4])
      end)
    end

    it("with a buffer that stays loaded in another window, whatever 'bufhidden' and 'hidden' say", function()
      state.bufhidden[OLD] = "wipe"
      vim.o.hidden = false

      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.equal("noautocmd set_buf 1001 8", log[2])
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
      state.current = OTHER_WIN
      vim.api.nvim_win_set_buf = function(win, buf)
        table.insert(log, string.format("plain set_buf %d %d eventignore=%s", win, buf, vim.o.eventignore))
      end

      utils.win_set_buf_in_split(SPLIT, TERMINAL, { ignore_bufenter = true })

      assert.same({ "plain set_buf 1001 8 eventignore=BufEnter" }, log)
      assert.equal("", vim.o.eventignore)
    end)

    it("gives 'eventignore' back and raises the same error when the swap fails", function()
      vim.o.eventignore = "CursorHold"
      state.raise = true

      local ok, err = pcall(utils.win_set_buf_in_split, SPLIT, TERMINAL, { ignore_bufenter = true })

      assert.is_false(ok)
      assert.equal("E5555: no", err)
      assert.equal("CursorHold", vim.o.eventignore)
    end)
  end)

  it("leaves 'eventignore' alone without ignore_bufenter", function()
    vim.o.eventignore = "CursorHold"

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    for _, seen in ipairs(state.eventignore_seen) do
      assert.equal("CursorHold", seen)
    end
  end)
end)

require("tests.busted_setup")

-- Fakes only what `utils.win_set_buf_in_split` reads and calls, and logs what it does in order. The behavior in a real
-- Neovim (where the terminal lands, the events that Neovim fires) is in tests/integration/terminal_placement_spec.lua.
describe("claudecode.utils.win_set_buf_in_split", function()
  local utils = require("claudecode.utils")

  local SPLIT, OTHER, OLD, TERMINAL = 1001, 1002, 7, 8
  local saved
  local state
  local log

  local function stub(parent, name, value)
    saved[#saved + 1] = { parent = parent, name = name, value = parent[name] }
    parent[name] = value
  end

  before_each(function()
    saved = {}
    log = {}
    state = {
      current = SPLIT,
      win_bufs = { [SPLIT] = OLD, [OTHER] = OLD },
      bo = { [OLD] = { modified = false, bufhidden = "" } },
      hidden = true,
      abuf = "",
      cmdwin = "",
      winfixbuf = false,
      winfixbuf_option = true,
      invalid_wins = {},
      invalid_bufs = {},
    }

    stub(vim.o, "eventignore", "")
    stub(vim.o, "hidden", true)
    stub(vim.api, "nvim_get_current_win", function()
      return state.current
    end)
    stub(vim.api, "nvim_win_get_buf", function(win)
      return state.win_bufs[win]
    end)
    stub(vim.api, "nvim_win_is_valid", function(win)
      return not state.invalid_wins[win]
    end)
    stub(vim.api, "nvim_buf_is_valid", function(buf)
      return not state.invalid_bufs[buf]
    end)
    stub(vim.api, "nvim_win_get_option", function(_, name)
      assert.equal("winfixbuf", name)
      if not state.winfixbuf_option then
        error("Invalid option name: 'winfixbuf'", 0)
      end
      return state.winfixbuf
    end)
    stub(
      vim,
      "wo",
      setmetatable({}, {
        __index = function()
          return { winfixbuf = state.winfixbuf }
        end,
      })
    )
    stub(
      vim,
      "bo",
      setmetatable({}, {
        __index = function(_, buf)
          return state.bo[buf] or { modified = false, bufhidden = "" }
        end,
      })
    )
    stub(vim.fn, "win_findbuf", function(buf)
      local wins = {}
      for _, win in ipairs({ SPLIT, OTHER }) do
        if state.win_bufs[win] == buf then
          table.insert(wins, win)
        end
      end
      return wins
    end)
    stub(vim.fn, "getcmdwintype", function()
      return state.cmdwin
    end)
    stub(vim.fn, "expand", function(what)
      assert.equal("<abuf>", what)
      if state.expand_raises then
        error("E496", 0)
      end
      return state.abuf
    end)
    stub(vim.api, "nvim_win_set_buf", function(win, buf)
      table.insert(log, string.format("plain set_buf %d %d eventignore=%s", win, buf, vim.o.eventignore))
      if state.raise_on_swap then
        error("E37: No write since last change", 0)
      end
      state.win_bufs[win] = buf
    end)
    stub(vim, "cmd", function(command)
      if command == "doautocmd <nomodeline> BufLeave" then
        table.insert(log, "BufLeave")
        if state.on_bufleave then
          state.on_bufleave()
        end
        return
      end
      local target = command:match("^noautocmd call nvim_set_current_win%((%d+)%)$")
      if target then
        table.insert(log, "noautocmd enter " .. target)
        state.current = tonumber(target)
        return
      end
      local ignore, buf = command:match('^noautocmd lua vim%.o%.eventignore = "(.-)"; vim%.cmd%("buffer! (%d+)"%)$')
      assert.is_not_nil(ignore, "unexpected command: " .. command)
      table.insert(log, string.format("noautocmd swap %d %s eventignore=%s", state.current, buf, ignore))
      state.win_bufs[state.current] = tonumber(buf)
    end)
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      local entry = saved[i]
      entry.parent[entry.name] = entry.value
    end
  end)

  it("fires BufLeave, then swaps under :noautocmd with BufLeave and OptionSet ignored", function()
    local placed = utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.is_true(placed)
    assert.same({
      "BufLeave",
      "noautocmd swap 1001 8 eventignore=BufLeave,OptionSet",
    }, log)
    assert.equal(TERMINAL, state.win_bufs[SPLIT])
    assert.equal("", vim.o.eventignore, "the caller's value is not written, :noautocmd sets it again itself")
  end)

  it("fires no other event itself", function()
    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    for _, line in ipairs(log) do
      for _, event in ipairs({ "BufWinLeave", "BufHidden", "BufUnload", "BufEnter", "BufWinEnter", "WinEnter" }) do
        assert.is_nil(line:find(event, 1, true), line)
      end
    end
  end)

  it("puts the cursor back in the split, with no event, when an autocmd of BufLeave entered another window", function()
    state.on_bufleave = function()
      state.current = OTHER
    end

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.same({
      "BufLeave",
      "noautocmd enter 1001",
      "noautocmd swap 1001 8 eventignore=BufLeave,OptionSet",
    }, log)
    assert.equal(SPLIT, state.current)
  end)

  it("shows nothing, and returns false, when an autocmd of BufLeave closed the split", function()
    state.on_bufleave = function()
      state.invalid_wins[SPLIT] = true
      state.current = OTHER
    end

    local placed = utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.is_false(placed)
    assert.same({ "BufLeave" }, log)
    assert.equal(OTHER, state.current)
  end)

  it("shows nothing, and returns false, when an autocmd of BufLeave wiped the buffer to show", function()
    state.on_bufleave = function()
      state.invalid_bufs[TERMINAL] = true
    end

    local placed = utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.is_false(placed)
    assert.same({ "BufLeave" }, log)
  end)

  it("raises the error of an autocmd of BufLeave and swaps nothing", function()
    state.on_bufleave = function()
      error("USER ERROR", 0)
    end

    assert.has_error(function()
      utils.win_set_buf_in_split(SPLIT, TERMINAL)
    end, "USER ERROR")
    assert.same({ "BufLeave" }, log)
  end)

  describe("with 'eventignore'", function()
    it("adds BufLeave and OptionSet to the caller's value, and keeps the caller's entries", function()
      vim.o.eventignore = "CursorHold,FocusGained"

      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.same({
        "BufLeave",
        "noautocmd swap 1001 8 eventignore=CursorHold,FocusGained,BufLeave,OptionSet",
      }, log)
    end)

    it("drops a -BufLeave and a -OptionSet entry, because they would beat the entries that it adds", function()
      vim.o.eventignore = "-BufLeave,CursorHold,-OptionSet"

      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.same({
        "BufLeave",
        "noautocmd swap 1001 8 eventignore=CursorHold,BufLeave,OptionSet",
      }, log)
    end)
  end)

  describe("with ignore_bufenter", function()
    it("adds BufEnter to the events of the swap, and drops a -BufEnter entry", function()
      vim.o.eventignore = "-BufEnter,CursorHold"

      utils.win_set_buf_in_split(SPLIT, TERMINAL, { ignore_bufenter = true })

      assert.same({
        "BufLeave",
        "noautocmd swap 1001 8 eventignore=CursorHold,BufLeave,OptionSet,BufEnter",
      }, log)
    end)

    it("ignores BufEnter in a plain swap too, and gives 'eventignore' back", function()
      state.win_bufs[SPLIT] = TERMINAL
      vim.o.eventignore = "-BufEnter,CursorHold"
      stub(vim.api, "nvim_win_set_buf", function(win, buf)
        table.insert(log, string.format("plain set_buf %d %d eventignore=%s", win, buf, vim.o.eventignore))
      end)

      utils.win_set_buf_in_split(SPLIT, TERMINAL, { ignore_bufenter = true })

      assert.same({ "plain set_buf 1001 8 eventignore=CursorHold,BufEnter" }, log)
      assert.equal("-BufEnter,CursorHold", vim.o.eventignore)
    end)

    it("gives 'eventignore' back and raises the same error when a plain swap fails", function()
      state.cmdwin = ":"
      state.raise_on_swap = true
      vim.o.eventignore = "CursorHold"

      assert.has_error(function()
        utils.win_set_buf_in_split(SPLIT, TERMINAL, { ignore_bufenter = true })
      end, "E37: No write since last change")
      assert.equal("CursorHold", vim.o.eventignore)
    end)
  end)

  describe("makes a plain swap, with no BufLeave of its own,", function()
    local function expect_plain()
      local placed = utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.is_true(placed)
      assert.same({ "plain set_buf 1001 8 eventignore=" }, log)
    end

    it("when the split is not the current window", function()
      state.current = OTHER

      expect_plain()
    end)

    it("when the split already shows the buffer", function()
      state.win_bufs[SPLIT] = TERMINAL

      expect_plain()
    end)

    it("inside an autocmd, where Neovim fires no event of the swap and a fired BufLeave would run alone", function()
      state.abuf = "7"

      expect_plain()
    end)

    it("in the command-line window", function()
      state.cmdwin = ":"

      expect_plain()
    end)

    it("when the split has 'winfixbuf', which a plain swap refuses and :buffer! would override", function()
      state.winfixbuf = true

      expect_plain()
    end)

    it(
      "when a plain swap could refuse to leave the buffer: it is changed, not hidden, and shown in one window",
      function()
        state.bo[OLD] = { modified = true, bufhidden = "" }
        state.win_bufs[OTHER] = nil
        vim.o.hidden = false

        expect_plain()
      end
    )

    it("when its 'bufhidden' is wipe, because wipe is not hide", function()
      state.bo[OLD] = { modified = true, bufhidden = "wipe" }
      state.win_bufs[OTHER] = nil
      vim.o.hidden = true

      expect_plain()
    end)
  end)

  describe("fires BufLeave first", function()
    local function expect_leave_first()
      utils.win_set_buf_in_split(SPLIT, TERMINAL)

      assert.same({ "BufLeave", "noautocmd swap 1001 8 eventignore=BufLeave,OptionSet" }, log)
    end

    it("for a changed buffer when 'hidden' is on, which a plain swap hides", function()
      state.bo[OLD] = { modified = true, bufhidden = "" }
      state.win_bufs[OTHER] = nil
      vim.o.hidden = true

      expect_leave_first()
    end)

    it("for a changed buffer whose 'bufhidden' is hide", function()
      state.bo[OLD] = { modified = true, bufhidden = "hide" }
      state.win_bufs[OTHER] = nil
      vim.o.hidden = false

      expect_leave_first()
    end)

    it("for a changed buffer that another window shows", function()
      state.bo[OLD] = { modified = true, bufhidden = "" }
      vim.o.hidden = false

      expect_leave_first()
    end)

    it("for a buffer with no change, shown in no other window", function()
      state.win_bufs[OTHER] = nil
      vim.o.hidden = false

      expect_leave_first()
    end)

    it("when 'winfixbuf' is an unknown option, as in Neovim 0.8", function()
      state.winfixbuf_option = false

      expect_leave_first()
    end)

    it("when expanding <abuf> raises", function()
      state.expand_raises = true

      expect_leave_first()
    end)
  end)

  it("raises the same error when the swap fails, after BufLeave", function()
    stub(vim, "cmd", function(command)
      table.insert(log, command)
      if command:find("buffer!", 1, true) then
        error("E86: Buffer 8 does not exist", 0)
      end
    end)

    assert.has_error(function()
      utils.win_set_buf_in_split(SPLIT, TERMINAL)
    end, "E86: Buffer 8 does not exist")
    assert.equal("doautocmd <nomodeline> BufLeave", log[1])
  end)
end)

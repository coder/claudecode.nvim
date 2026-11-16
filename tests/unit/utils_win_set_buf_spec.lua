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
    stub(vim.api, "nvim_get_option_value", function(name, opts)
      assert.equal("winfixbuf", name)
      assert.same({ win = SPLIT }, opts)
      if not state.winfixbuf_option then
        error("Invalid option name: 'winfixbuf'", 0)
      end
      return state.winfixbuf
    end)
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
    stub(vim, "v", { errmsg = "earlier error" })
    stub(vim.fn, "expand", function(what)
      assert.equal("<abuf>", what)
      if state.verbose and state.abuf == "" then
        -- Neovim raises this outside an autocmd when 'verbose' is above 0, for any level, on every Neovim we run.
        -- Under `:silent!` it gives "" and sets v:errmsg instead.
        local message = 'E496: No autocommand buffer number to substitute for "<abuf>"'
        if state.silent then
          vim.v.errmsg = message
          return ""
        end
        error(message, 0)
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
      local target_buf, value = command:match("^noautocmd call setbufvar%((%d+), '&bufhidden', (.-)%)$")
      if target_buf then
        value = value:match("^'(.*)'$") or value:match('^"(.*)"$')
        table.insert(log, string.format("noautocmd bufhidden %s %s", target_buf, value))
        state.bo[tonumber(target_buf)] = state.bo[tonumber(target_buf)] or { modified = false }
        state.bo[tonumber(target_buf)].bufhidden = value
        return
      end
      local ignore, buf = command:match('^noautocmd lua vim%.o%.eventignore = "(.-)"; vim%.cmd%("buffer! (%d+)"%)$')
      assert.is_not_nil(ignore, "unexpected command: " .. command)
      table.insert(log, string.format("noautocmd swap %d %s eventignore=%s", state.current, buf, ignore))
      state.bufhidden_at_swap = (state.bo[state.win_bufs[state.current]] or {}).bufhidden
      state.win_bufs[state.current] = tonumber(buf)
      if state.on_swap then
        state.on_swap()
      end
      if state.raise_on_buffer_swap then
        error("USER ERROR", 0)
      end
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

  it("fires BufLeave first, outside an autocmd, when 'verbose' is above 0 and expand of <abuf> raises", function()
    state.verbose = true

    local placed = utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.is_true(placed)
    assert.same({
      "BufLeave",
      "noautocmd swap 1001 8 eventignore=BufLeave,OptionSet",
    }, log)
  end)

  it("gives v:errmsg back as it was, also when expand of <abuf> failed under :silent!", function()
    state.verbose = true
    state.silent = true

    utils.win_set_buf_in_split(SPLIT, TERMINAL)

    assert.equal("earlier error", vim.v.errmsg)
    assert.same({
      "BufLeave",
      "noautocmd swap 1001 8 eventignore=BufLeave,OptionSet",
    }, log)
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

  describe("when the buffer in the split cannot be left by a plain swap", function()
    local SHOWN = 9
    local HIDE_FIRST = "noautocmd bufhidden 9 hide"
    local SWAP = "noautocmd swap 1001 8 eventignore=BufLeave,OptionSet"

    ---The autocmd puts `SHOWN` in the split, with the options in `bo`. No other window shows it.
    local function show_other(bo)
      state.on_bufleave = function()
        state.win_bufs[SPLIT] = SHOWN
        state.bo[SHOWN] = bo
      end
    end

    -- `:buffer!` skips the E37 check of a plain swap, and it unloads or wipes a changed buffer with these values of
    -- 'bufhidden', where a plain swap keeps the text. So the buffer is hidden for the swap and gets its value back.
    for _, bufhidden in ipairs({ "unload", "delete", "wipe" }) do
      it("hides a changed buffer for the swap, and gives back its 'bufhidden' " .. bufhidden, function()
        show_other({ modified = true, bufhidden = bufhidden })
        vim.o.hidden = true

        local placed = utils.win_set_buf_in_split(SPLIT, TERMINAL)

        assert.is_true(placed)
        assert.same({ "BufLeave", HIDE_FIRST, SWAP, "noautocmd bufhidden 9 " .. bufhidden }, log)
        assert.equal("hide", state.bufhidden_at_swap)
        assert.equal(bufhidden, state.bo[SHOWN].bufhidden)
        assert.equal(TERMINAL, state.win_bufs[SPLIT])
      end)
    end

    it("hides a changed buffer for the swap when 'hidden' is off and its 'bufhidden' is empty", function()
      show_other({ modified = true, bufhidden = "" })
      vim.o.hidden = false

      assert.is_true(utils.win_set_buf_in_split(SPLIT, TERMINAL))
      assert.same({ "BufLeave", HIDE_FIRST, SWAP, "noautocmd bufhidden 9 " }, log)
      assert.equal("", state.bo[SHOWN].bufhidden)
    end)

    it("hides the buffer of the split for the swap when an autocmd closed its other window", function()
      -- The first check passed, because a second window showed the buffer. A plain swap decided then too, and keeps it.
      state.bo[OLD] = { modified = true, bufhidden = "wipe" }
      vim.o.hidden = false
      state.on_bufleave = function()
        state.win_bufs[OTHER] = nil
      end

      assert.is_true(utils.win_set_buf_in_split(SPLIT, TERMINAL))
      assert.same({ "BufLeave", "noautocmd bufhidden 7 hide", SWAP, "noautocmd bufhidden 7 wipe" }, log)
    end)

    it("hides the terminal's own buffer for the swap, and gives it back, when an autocmd showed it already", function()
      show_other({ modified = true, bufhidden = "wipe" })
      state.on_bufleave = function()
        state.win_bufs[SPLIT] = TERMINAL
        state.bo[TERMINAL] = { modified = true, bufhidden = "wipe" }
      end

      assert.is_true(utils.win_set_buf_in_split(SPLIT, TERMINAL))
      assert.same({ "BufLeave", "noautocmd bufhidden 8 hide", SWAP, "noautocmd bufhidden 8 wipe" }, log)
    end)

    it("gives the 'bufhidden' back, and raises the error of the swap, when the swap fails", function()
      show_other({ modified = true, bufhidden = "wipe" })
      state.raise_on_buffer_swap = true

      local ok, err = pcall(utils.win_set_buf_in_split, SPLIT, TERMINAL)

      assert.is_false(ok)
      -- The error comes through as it is, with no position of the helper in front of it.
      assert.equal("USER ERROR", err)
      assert.same({ "BufLeave", HIDE_FIRST, SWAP, "noautocmd bufhidden 9 wipe" }, log)
    end)

    it("gives nothing back, and raises no error, when an autocmd of the swap wiped the buffer", function()
      show_other({ modified = true, bufhidden = "wipe" })
      state.on_swap = function()
        state.invalid_bufs[SHOWN] = true
      end

      assert.is_true(utils.win_set_buf_in_split(SPLIT, TERMINAL))
      assert.same({ "BufLeave", HIDE_FIRST, SWAP }, log)
    end)

    it("leaves the options of a changed buffer that 'hidden' hides alone", function()
      show_other({ modified = true, bufhidden = "" })
      vim.o.hidden = true

      assert.is_true(utils.win_set_buf_in_split(SPLIT, TERMINAL))
      assert.same({ "BufLeave", SWAP }, log)
    end)

    it("leaves the options of a changed buffer whose 'bufhidden' is hide alone", function()
      show_other({ modified = true, bufhidden = "hide" })
      vim.o.hidden = false

      assert.is_true(utils.win_set_buf_in_split(SPLIT, TERMINAL))
      assert.same({ "BufLeave", SWAP }, log)
    end)

    it("leaves the options of a changed buffer that another window shows too alone", function()
      show_other({ modified = true, bufhidden = "wipe" })
      vim.o.hidden = true
      local show = state.on_bufleave
      state.on_bufleave = function()
        show()
        state.win_bufs[OTHER] = SHOWN
      end

      assert.is_true(utils.win_set_buf_in_split(SPLIT, TERMINAL))
      assert.same({ "BufLeave", SWAP }, log)
    end)

    -- A plain swap leaves any buffer that an autocmd showed in the split, changed or not: a terminal with a running job
    -- and a scratch buffer have no change to refuse for, and `:buffer!` would unload or wipe them.
    for _, bufhidden in ipairs({ "unload", "delete", "wipe" }) do
      it("hides a buffer with no change that an autocmd showed for the swap, with 'bufhidden' " .. bufhidden, function()
        show_other({ modified = false, bufhidden = bufhidden })
        vim.o.hidden = true

        assert.is_true(utils.win_set_buf_in_split(SPLIT, TERMINAL))
        assert.same({ "BufLeave", HIDE_FIRST, SWAP, "noautocmd bufhidden 9 " .. bufhidden }, log)
        assert.equal("hide", state.bufhidden_at_swap)
      end)
    end

    it(
      "hides a buffer with no change that an autocmd showed when 'hidden' is off and its 'bufhidden' is empty",
      function()
        show_other({ modified = false, bufhidden = "" })
        vim.o.hidden = false

        assert.is_true(utils.win_set_buf_in_split(SPLIT, TERMINAL))
        assert.same({ "BufLeave", HIDE_FIRST, SWAP, "noautocmd bufhidden 9 " }, log)
      end
    )

    it("leaves the options of a buffer with no change that 'hidden' hides alone", function()
      show_other({ modified = false, bufhidden = "" })
      vim.o.hidden = true

      assert.is_true(utils.win_set_buf_in_split(SPLIT, TERMINAL))
      assert.same({ "BufLeave", SWAP }, log)
    end)

    it("leaves the options of the buffer of the split with no change alone, as a plain swap does", function()
      state.bo[OLD] = { modified = false, bufhidden = "wipe" }
      vim.o.hidden = false

      assert.is_true(utils.win_set_buf_in_split(SPLIT, TERMINAL))
      assert.same({ "BufLeave", SWAP }, log)
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

    it("inside an autocmd with 'verbose' above 0", function()
      state.abuf = "7"
      state.verbose = true

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

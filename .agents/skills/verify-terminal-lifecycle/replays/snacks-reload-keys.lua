-- HideKeepsClaude: after a reload, the keys in the window of an adopted snacks Claude must act on the terminal as it is now.
-- Snacks maps the keys of an instance to the buffer, and each map closes over that instance. The maps of the first start
-- close over the instance that started the Claude. Once the provider has hidden and shown the adopted terminal in a new
-- window, that instance has a stale window, so q did nothing and gf left the file in Claude's window, and a key of the
-- user's that calls self:hide() did nothing after the float was closed and opened again.
-- Path (a split on the right, and a float): you open Claude; the plugin reloads (once, then twice); a toggle adopts and hides
-- it; a toggle shows it; you press q in its window (normal mode); Claude must be hidden. Then Claude is shown again, the
-- cursor is on the file name that Claude printed, and you press gf: Claude must be hidden, and its window must not show
-- the file. A float with a hide key of the user's (a function): the float is closed and opened again, and the key must
-- hide it.
-- Main has no bug here. The replay guards the wrapper that #482 builds: a BUG line means a key acts on a stale instance.
local lib = dofile(os.getenv("REPLAY_LIB"))
vim.o.termguicolors = true
vim.fn.writefile({ "file a" }, vim.fn.getcwd() .. "/a.txt")

-- Whether a window shows Claude and is not hidden.
local function shown(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if not vim.api.nvim_win_get_config(win).hide then
      return true
    end
  end
  return false
end

local function claude_window(buf)
  return vim.fn.win_findbuf(buf)[1]
end

local function cleanup()
  for _, buf in ipairs(lib.running()) do
    vim.b[buf].claudecode_snacks_terminal = nil
    pcall(vim.fn.jobstop, vim.bo[buf].channel)
  end
  lib.wait(300)
  vim.cmd("silent! only")
  vim.cmd("silent! %bwipeout!")
end

-- Reloads the plugin `reloads` times, with a toggle that adopts and hides and a toggle that shows after each.
local function reload_and_cycle(setup, term, reloads)
  for _ = 1, reloads do
    term = lib.reload(setup)
    term.simple_toggle()
    term.simple_toggle()
    lib.settle()
  end
  return term
end

for _, position in ipairs({ "right", "float" }) do
  for reloads = 1, 2 do
    lib.attempt(string.format("%s, %d reload(s)", position, reloads), function()
      local function setup()
        local term = require("claudecode.terminal")
        term.setup({
          provider = "snacks",
          auto_close = true,
          snacks_win_opts = position == "float" and { position = "float", width = 0.6, height = 0.5 } or nil,
        }, "sh -c 'echo a.txt; sleep 60'")
        return term
      end
      local term = lib.reload(setup)
      term.open()
      lib.settle()
      vim.cmd("stopinsert")
      local claude = term.get_active_terminal_bufnr()
      term = reload_and_cycle(setup, term, reloads)

      vim.api.nvim_set_current_win(claude_window(claude))
      vim.cmd("stopinsert")
      vim.api.nvim_feedkeys("q", "tx", false)
      lib.wait(100)
      lib.step(
        string.format(
          "%s, %d reload(s), a hide and a show, then q in Claude's window: Claude is %s",
          position,
          reloads,
          shown(claude) and "still shown" or "hidden"
        ),
        shown(claude)
      )

      if not shown(claude) then
        term.simple_toggle()
        lib.settle()
      end
      local win = claude_window(claude)
      vim.api.nvim_set_current_win(win)
      vim.cmd("stopinsert")
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      vim.api.nvim_feedkeys("gf", "tx", false)
      lib.wait(400)
      local in_claude_window = vim.api.nvim_win_is_valid(win)
          and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)), ":t")
        or "-"
      lib.step(
        string.format(
          "%s, %d reload(s), a hide and a show, then gf on a file name: Claude is %s, its window shows %s",
          position,
          reloads,
          shown(claude) and "still shown" or "hidden",
          in_claude_window
        ),
        shown(claude) or in_claude_window == "a.txt"
      )
    end)
    cleanup()
  end
end

-- A key of the user's, with a function, in a float: the entry's config gives it to the wrapper, and a buffer variable
-- could not keep it.
for reloads = 1, 2 do
  lib.attempt(string.format("float with a hide key, %d reload(s)", reloads), function()
    local function setup()
      local term = require("claudecode.terminal")
      term.setup({
        provider = "snacks",
        auto_close = true,
        snacks_win_opts = {
          position = "float",
          width = 0.6,
          height = 0.5,
          keys = {
            claude_hide = {
              "<C-q>",
              function(self)
                self:hide()
              end,
              mode = "t",
              desc = "Hide",
            },
          },
        },
      }, "sh -c 'sleep 60'")
      return term
    end
    local term = lib.reload(setup)
    term.open()
    lib.settle()
    local claude = term.get_active_terminal_bufnr()
    term = reload_and_cycle(setup, term, reloads)
    -- The float is closed, and an open makes a new one.
    vim.api.nvim_set_current_win(claude_window(claude))
    vim.cmd("close")
    lib.settle()
    term.open()
    lib.settle()
    local win = claude_window(claude)
    vim.api.nvim_set_current_win(win)
    -- Headless Neovim does not enter terminal mode from startinsert here, so run the map of the key as typing it would.
    local map = vim.api.nvim_buf_call(claude, function()
      return vim.fn.maparg("<C-q>", "t", false, true)
    end)
    if map.callback then
      vim.api.nvim_win_call(win, map.callback)
    end
    lib.wait(100)
    lib.step(
      string.format(
        "float with a hide key of the user's, %d reload(s), closed and opened: after the key Claude is %s",
        reloads,
        shown(claude) and "still shown" or "hidden"
      ),
      map.callback == nil or shown(claude)
    )
  end)
  cleanup()
end

-- A key that the user turned off (`false`) must stay off. An entry without a config (selection tracking calls
-- get_active_terminal_bufnr on a cursor move) wraps the terminal, and a map made there, without the user's keys, would turn
-- the style's double-Esc key on: Snacks never removes a map. The key that the user maps to <Esc> must stay theirs too.
for _, case in ipairs({
  { name = "term_normal = false", keys = { term_normal = false } },
  { name = "a hide key on <Esc>", keys = { claude_esc = { "<Esc>", "hide", mode = "t", desc = "Hide" } } },
}) do
  lib.attempt(case.name, function()
    local function setup()
      local term = require("claudecode.terminal")
      term.setup({
        provider = "snacks",
        auto_close = true,
        snacks_win_opts = { keys = case.keys },
      }, "sh -c 'sleep 60'")
      return term
    end
    local function esc_key(buf)
      local map = vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg("<Esc>", "t", false, true)
      end)
      return map.desc or ""
    end
    local term = lib.reload(setup)
    term.open()
    lib.settle()
    local claude = term.get_active_terminal_bufnr()
    local started = esc_key(claude)
    term = lib.reload(setup)
    term.get_active_terminal_bufnr()
    local configless = esc_key(claude)
    term.simple_toggle()
    term.simple_toggle()
    lib.settle()
    local configured = esc_key(claude)
    lib.step(
      string.format(
        "%s: the <Esc> map of Claude is %q at the start, %q after a reload and an entry without a config, %q after a hide and a show",
        case.name,
        started,
        configless,
        configured
      ),
      configless ~= started or configured ~= started
    )
  end)
  cleanup()
end
lib.finish()

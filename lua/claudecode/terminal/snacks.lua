---Snacks.nvim terminal provider for Claude Code.
---@module 'claudecode.terminal.snacks'

local M = {}

local snacks_available, Snacks = pcall(require, "snacks")
local owned = require("claudecode.terminal.owned")
local utils = require("claudecode.utils")
local terminal = nil
-- True while Snacks.terminal.open runs in M.open. `terminal` is set only after it returns.
local starting = false

-- Set on each terminal buffer this provider starts. Unlike `terminal`, a buffer variable survives a reload of this
-- module, so the next module instance can find the terminal again.
local OWNED_MARK = owned.SNACKS_MARK

-- Written on each terminal buffer this provider starts: whether it started with auto_close, its window options (as
-- plain data: position, size, border and so on), and the window of its float's backdrop (another Snacks float can have
-- a backdrop at the same z-index, so the id decides). A buffer variable survives a reload of this module, like the
-- mark, so the next module instance knows them without the Snacks instance.
local AUTO_CLOSE_VAR = "claudecode_snacks_auto_close"
local WINDOW_VAR = "claudecode_snacks_window"
local BACKDROP_VAR = "claudecode_snacks_backdrop"

--- @return boolean
local function is_available()
  return snacks_available and Snacks and Snacks.terminal ~= nil
end

---Setup event handlers for terminal instance
---@param term_instance table The Snacks terminal instance
---@param config table Configuration options
local function setup_terminal_events(term_instance, config)
  local logger = require("claudecode.logger")

  -- A terminal opened while this one was closing is the tracked one now, so keep tracking it.
  local function forget()
    if terminal == term_instance then
      terminal = nil
    end
  end

  -- Handle command completion/exit - only if auto_close is enabled
  if config.auto_close then
    term_instance:on("TermClose", function()
      -- The native provider's direct stop of this Claude (owned.stop_other) clears the mark first, so the exit that it
      -- causes is no error.
      local stopped_elsewhere = term_instance:buf_valid() and not vim.b[term_instance.buf][OWNED_MARK]
      if vim.v.event.status ~= 0 and not term_instance._cc.closing and not stopped_elsewhere then
        logger.error("terminal", "Claude exited with code " .. vim.v.event.status .. ".\nCheck for any errors.")
      end

      -- Clean up
      forget()
      vim.schedule(function()
        term_instance:close({ buf = true })
        vim.cmd.checktime()
      end)
    end, { buf = true })
  end

  -- Handle buffer deletion
  term_instance:on("BufWipeout", function()
    logger.debug("terminal", "Terminal buffer wiped")
    forget()
  end, { buf = true })
end

---A copy of a table without the values that a buffer variable cannot hold (functions), so that it can be stored.
---@param value any
---@return any copy nil for a function
local function plain(value)
  local kind = type(value)
  if kind == "function" or kind == "userdata" or kind == "thread" then
    return nil
  end
  if kind ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = plain(item)
  end
  return copy
end

---Builds Snacks terminal options with focus control
---@param config ClaudeCodeTerminalConfig Terminal configuration
---@param env_table table Environment variables to set for the terminal process
---@param focus boolean|nil Whether to focus the terminal when opened (defaults to true)
---@return snacks.terminal.Opts opts
local function build_opts(config, env_table, focus)
  focus = utils.normalize_focus(focus)
  local auto_insert = config.auto_insert ~= false
  -- Snacks enters every window it opens (#423).
  local enter = nil
  if not focus then
    enter = false
  end
  return {
    env = env_table,
    cwd = config.cwd,
    start_insert = focus and auto_insert,
    auto_insert = auto_insert,
    auto_close = false,
    win = vim.tbl_deep_extend("force", {
      position = config.split_side,
      width = config.split_width_percentage,
      height = 0,
      relative = "editor",
      enter = enter,
      -- Default, not a lock. Snacks' terminal style would set "snacks_terminal", and Snacks re-applies `bo` each time
      -- it re-creates a floating window, so the filetype goes through the options, not a write after open.
      -- `snacks_win_opts.bo.filetype` wins.
      bo = { filetype = "claudecode" },
      keys = {
        claude_new_line = {
          "<S-CR>",
          function()
            vim.api.nvim_feedkeys("\\", "t", true)
            vim.defer_fn(function()
              vim.api.nvim_feedkeys("\r", "t", true)
            end, 10)
          end,
          mode = "t",
          desc = "New line",
        },
      },
    } --[[@as snacks.win.Config]], config.snacks_win_opts or {}),
  } --[[@as snacks.terminal.Opts]]
end

-- ---------------------------------------------------------------------------
-- Climbing-cursor workaround (#240 split / #183 float).
--
-- Snacks hides a terminal by CLOSING its window (nvim_win_close) and re-shows it
-- by recreating the window in open_win(). That recreate leaves Claude's terminal
-- cursor anchor one row off; Claude (Ink) re-renders relative to the cursor on
-- the focus-in event Neovim sends when the window is shown, so the prompt climbs
-- one row per toggle. Neither a pty resize nor the focus event alone causes it --
-- it is the destroy+recreate of the window. To avoid disturbing the anchor we
-- manage hide/show ourselves:
--   * floating window -> nvim_win_set_config({hide=true/false}) keeps the window
--     (and its grid/cursor) alive. Requires nvim-0.10 (the `hide` win-config field).
--   * split window -> cannot be config-hidden, so close on hide and recreate with
--     a plain vsplit + nvim_win_set_buf on show, exactly like the native provider
--     (which does not drift). Buffer-local state (the <S-CR> map) survives.
-- ---------------------------------------------------------------------------

local function win_get_config(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  if ok then
    return cfg
  end
  return nil
end

-- A real split window reports relative == "" regardless of the opts Snacks was
-- given; a float reports "editor"/"win"/"cursor".
local function win_is_floating(win)
  local cfg = win_get_config(win)
  return cfg ~= nil and cfg.relative ~= nil and cfg.relative ~= ""
end

local function win_is_config_hidden(win)
  local cfg = win_get_config(win)
  return cfg ~= nil and cfg.hide == true
end

local function supports_config_hide()
  return vim.fn ~= nil and vim.fn.has ~= nil and vim.fn.has("nvim-0.10") == 1
end

-- Resolve a Snacks width/height value to an absolute cell count: a fraction in
-- (0,1) scales `total`; a value >= 1 is taken as absolute; otherwise fall back
-- to `default_frac` of `total`.
local function resolve_split_size(val, total, default_frac)
  if type(val) == "number" and val > 0 then
    if val < 1 then
      return math.max(1, math.floor(total * val))
    end
    return math.floor(val)
  end
  return math.max(1, math.floor(total * default_frac))
end

local function start_insert_if_terminal(term)
  if
    term.buf
    and vim.api.nvim_buf_is_valid(term.buf)
    and vim.api.nvim_buf_get_option(term.buf, "buftype") == "terminal"
    and term.win
    and vim.api.nvim_win_is_valid(term.win)
  then
    vim.api.nvim_win_call(term.win, function()
      vim.cmd("startinsert")
    end)
  end
end

-- Enter insert mode unless the user opted out via terminal.auto_insert = false
-- (issue #232). When disabled, re-focusing the terminal window keeps Normal mode
-- and preserves the scroll position instead of jumping to the prompt.
local function maybe_start_insert(term, config)
  if not config or config.auto_insert ~= false then
    start_insert_if_terminal(term)
  end
end

-- Visible == a live window that shows our buffer and is not config-hidden.
local function cc_is_visible(term)
  local win = term and term.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  if win_is_config_hidden(win) then
    return false
  end
  -- Match Snacks' own valid() / the native provider: a window showing some other
  -- buffer is not "our" terminal being visible.
  return vim.api.nvim_win_get_buf(win) == term.buf
end

local function set_backdrop_hidden(term, hidden)
  if term.backdrop and term.backdrop.win and vim.api.nvim_win_is_valid(term.backdrop.win) then
    pcall(vim.api.nvim_win_set_config, term.backdrop.win, { hide = hidden })
  end
end

---Writes the backdrop window of a float to the buffer variable that an adoption after a reload reads, or clears the
---variable when the float has none. Snacks makes a new backdrop each time it re-creates a float, so this runs after
---each start and each re-creation.
---@param term table Snacks terminal instance
local function remember_backdrop(term)
  if not (term.buf and vim.api.nvim_buf_is_valid(term.buf)) then
    return
  end
  local backdrop = term.backdrop
  vim.b[term.buf][BACKDROP_VAR] = backdrop and backdrop.win or nil
end

---Registers what Snacks' Win:show registers when it opens a window: the instance's events that do not belong to one
---window (the resize of the backdrop and of the window), and the BufWinEnter handler that moves a file that you open in the
---terminal's window to another window (`fixbuf`). A wrapper starts without a Win:show, and cc_show re-creates a split
---without one (a float goes through Win:show, which registers them), so nothing else registers them, and an `:edit` in the
---re-created window would replace Claude's buffer. The WinClosed event is bound to the id of one window, and an instance
---that `snacks` started never has it for a window that cc_show re-created, so the wrapper registers none: Snacks' handler
---would move the cursor to the previous window (`wincmd p`) when the window closes, where main leaves it to Neovim. Win:show
---clears the augroup first, so a later Snacks show does not double them.
---@param term table Snacks terminal instance
local function register_window_events(term)
  if term._cc.events_registered or type(term._on) ~= "function" or type(term.fixbuf) ~= "function" then
    return
  end
  term._cc.events_registered = true
  term.augroup = vim.api.nvim_create_augroup("snacks_win_" .. term.id, { clear = true })
  for _, event in ipairs(term.events or {}) do
    if not event.win then
      term:_on(event.event, event)
    end
  end
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = term.augroup,
    nested = true,
    callback = function()
      return term:fixbuf()
    end,
  })
end

-- Re-apply the Snacks-managed window-local options/vars that are lost when a
-- split window is closed and recreated (minimal style turns off number/sign
-- column, sets winhighlight, etc.), so the re-shown split matches the original.
local function reapply_snacks_window_state(term, win)
  if not (term.opts and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if snacks_available and Snacks and Snacks.util and Snacks.util.wo and term.opts.wo then
    pcall(Snacks.util.wo, win, term.opts.wo)
  end
  for k, v in pairs(term.opts.w or {}) do
    pcall(function()
      vim.w[win][k] = v
    end)
  end
  -- Stacking marker so a second Snacks split can equalize against this one.
  pcall(function()
    vim.w[win].snacks_win = { id = term.id, position = term.opts.position }
  end)
end

---Hide the terminal window without disturbing the cursor anchor.
---@param term table Snacks terminal instance
local function cc_hide(term)
  if not cc_is_visible(term) then
    return
  end
  local logger = require("claudecode.logger")
  local win = term.win
  if win_is_floating(win) then
    if supports_config_hide() then
      logger.debug("terminal", "Snacks hide: config-hiding float (hide=true)")
      if term._cc then
        term._cc.kind = "float"
      end
      vim.api.nvim_win_set_config(win, { hide = true })
      set_backdrop_hidden(term, true)
      -- Neovim does not auto-leave a config-hidden window; step out of it.
      if vim.api.nvim_get_current_win() == win then
        pcall(vim.cmd, "wincmd p")
      end
    elseif term._cc and term._cc.orig_hide then
      -- Pre-0.10 float: no config-hide available, fall back to Snacks (cursor
      -- drift is not avoidable on these versions). Recreate as a float on show.
      logger.debug("terminal", "Snacks hide: pre-0.10 float via Snacks (drift unavoidable)")
      term._cc.kind = "float"
      term._cc.orig_hide(term)
    end
  else
    -- Split: close the window, keep the buffer + job alive. pcall so closing the
    -- LAST window (E444) is a harmless no-op instead of a throw; only forget the
    -- window on a successful close so state stays consistent.
    logger.debug("terminal", "Snacks hide: closing split window")
    if term._cc then
      term._cc.kind = "split"
    end
    if pcall(vim.api.nvim_win_close, win, false) then
      term.win = nil
    end
  end
end

---Show the terminal window, recreating splits the native way.
---@param term table Snacks terminal instance
---@param focus boolean Whether to focus the terminal and enter insert mode
---@param config table Effective terminal config (split_side, split_width_percentage)
---@return boolean shown
local function cc_show(term, focus, config)
  if not (term and term.buf and vim.api.nvim_buf_is_valid(term.buf)) then
    return false
  end
  local logger = require("claudecode.logger")
  local win = term.win

  -- Config-hidden float -> just un-hide it.
  if win and vim.api.nvim_win_is_valid(win) and win_is_config_hidden(win) then
    logger.debug("terminal", "Snacks show: un-hiding config-hidden float")
    vim.api.nvim_win_set_config(win, { hide = false })
    set_backdrop_hidden(term, false)
    if focus then
      vim.api.nvim_set_current_win(win)
      maybe_start_insert(term, config)
    end
    return true
  end

  -- Already visible -> optionally focus.
  if cc_is_visible(term) then
    if focus then
      vim.api.nvim_set_current_win(term.win)
      maybe_start_insert(term, config)
    end
    return true
  end

  -- Window is fully gone. Recreate it honoring the configured Snacks position:
  --   * float / any non-split position -> let Snacks re-create it (it owns the
  --     geometry); recreating it as a plain split would change its kind.
  --   * left/right -> vertical split, top/bottom -> horizontal split. Recreated
  --     natively (the drift-free path), sized from the resolved Snacks opts.
  local win_opts = (config and config.snacks_win_opts) or {}
  local position = win_opts.position or (config and config.split_side) or "right"
  local is_native_split = position == "left" or position == "right" or position == "top" or position == "bottom"
  if (not is_native_split or (term._cc and term._cc.kind == "float")) and term._cc and term._cc.orig_show then
    logger.debug("terminal", "Snacks show: re-creating via Snacks (position=" .. tostring(position) .. ")")
    term._cc.kind = nil
    if focus or win_opts.enter ~= nil then
      term._cc.orig_show(term)
    else
      -- In Snacks, opts.enter = false skips both entering the window and its queued insert.
      local snacks_opts = term.opts or {}
      local entered = snacks_opts.enter
      snacks_opts.enter = false
      local ok, err = pcall(term._cc.orig_show, term)
      snacks_opts.enter = entered
      if not ok then
        error(err, 0)
      end
    end
    remember_backdrop(term)
    if focus and term.win and vim.api.nvim_win_is_valid(term.win) then
      vim.api.nvim_set_current_win(term.win)
      maybe_start_insert(term, config)
    end
    return true
  end

  local original_win = vim.api.nvim_get_current_win()
  local horizontal = position == "top" or position == "bottom"
  local lead = (position == "top" or position == "left") and "topleft " or "botright "
  local new_win
  if horizontal then
    local height = resolve_split_size(win_opts.height, vim.o.lines, 0.30)
    logger.debug("terminal", "Snacks show: re-creating " .. position .. " split (native, h=" .. height .. ")")
    vim.cmd(lead .. height .. "split")
    new_win = vim.api.nvim_get_current_win()
  else
    local width = resolve_split_size(win_opts.width, vim.o.columns, (config and config.split_width_percentage) or 0.30)
    logger.debug("terminal", "Snacks show: re-creating " .. position .. " split (native, w=" .. width .. ")")
    vim.cmd(lead .. width .. "vsplit")
    new_win = vim.api.nvim_get_current_win()
  end
  -- Set term.win before nvim_win_set_buf so Snacks' fixbuf BufWinEnter autocmd
  -- (if still registered) sees a valid window and does not self-delete.
  term.win = new_win
  local placed
  if focus then
    placed = utils.win_set_buf_in_split(new_win, term.buf)
  else
    placed = utils.win_set_buf_in_split(new_win, term.buf, { ignore_bufenter = true })
  end
  if not placed then
    -- A BufLeave autocmd of the user's closed the split, so the terminal shows nowhere and stays hidden. Or it wiped the
    -- terminal's buffer, which closes no window and says nothing, as on main. Without focus, the cursor goes back to
    -- the window it was in, as after a show, unless that autocmd closed it.
    term.win = nil
    if vim.api.nvim_buf_is_valid(term.buf) then
      logger.one_line("warn", "terminal", "A BufLeave autocmd closed the terminal's window.")
    end
    if not focus and vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
    return false
  end
  if not horizontal then
    vim.api.nvim_win_set_height(new_win, vim.o.lines) -- full height for vertical splits, like native
  end
  term.closed = false
  reapply_snacks_window_state(term, new_win)
  if term.adopted then
    register_window_events(term)
  end
  if focus then
    maybe_start_insert(term, config)
  elseif vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
  end
  return true
end

---State stashed on a patched Snacks terminal instance.
---@class ClaudeCodeSnacksPatch
---@field orig_hide fun(self: table) Snacks' original Win:hide
---@field orig_show fun(self: table) Snacks' original Win:show
---@field orig_toggle fun(self: table) Snacks' original Win:toggle
---@field config table Effective terminal config captured at open time
---@field kind? "float"|"split" Window kind recorded at hide time
---@field closing? boolean Set by close(), so the job's exit status is not reported as a failure

-- Monkeypatch the Snacks terminal instance so hide/show/toggle -- including any
-- the user wires to Snacks keymaps (e.g. self:hide() in snacks_win_opts.keys) --
-- use the anchor-preserving paths above instead of Snacks' destroy+recreate.
local function patch_instance(term, config)
  term._cc = {
    orig_hide = term.hide,
    orig_show = term.show,
    orig_toggle = term.toggle,
    config = config,
  }
  function term:hide()
    cc_hide(self)
    return self
  end
  function term:show()
    cc_show(self, true, self._cc and self._cc.config)
    return self
  end
  function term:toggle()
    if cc_is_visible(self) then
      cc_hide(self)
    else
      cc_show(self, true, self._cc and self._cc.config)
    end
    return self
  end
end

---Forgets the tracked terminal when its Claude has exited and `auto_close` applies. An entry must start a new Claude
---then instead of showing it. The TermClose handler of setup_terminal_events forgets it too, but a TermClose autocmd
---that calls the plugin can run first (autocmds run in definition order), and an instance that an earlier copy of this
---module started has only that copy's handler, which clears only that copy's `terminal`. The close that the handler
---scheduled wipes the buffer later. Nothing is wiped here: a wipe while Neovim dispatches TermClose would delete the
---buffer-local autocmds that remain for that event.
local function forget_ended_terminal()
  if not (terminal and terminal:buf_valid()) then
    return
  end
  local started_with = terminal._cc and terminal._cc.config
  if started_with and started_with.auto_close and owned.job_ended(terminal.buf) then
    terminal = nil
  end
end

---The config of an adopted terminal: the config that the entry passes, except that `auto_close` is what the terminal
---started with, when the buffer says (an older version does not write it, so the entry's config decides).
---@param buf number
---@param config table|nil
---@return table
local function adopted_config(buf, config)
  local merged = {}
  for key, value in pairs(config or {}) do
    merged[key] = value
  end
  local started_with = vim.b[buf][AUTO_CLOSE_VAR]
  if started_with ~= nil then
    merged.auto_close = started_with
  end
  return merged
end

---The backdrop of a float, as Snacks made it for the first start: the window that the buffer variable names, if it is
---still one window below the float, with a buffer of filetype snacks_win_backdrop. Another Snacks float can have a
---backdrop at the same z-index, so the variable decides. The returned table has what the cc_* functions use of a Snacks
---backdrop (`win`) and what Snacks' own close calls (`close`).
---@param win number|nil The float
---@param buf number The terminal buffer
---@return table|nil backdrop
local function find_backdrop(win, buf)
  local backdrop = vim.b[buf][BACKDROP_VAR]
  if not (win and backdrop and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_is_valid(backdrop)) then
    return nil
  end
  local zindex = vim.api.nvim_win_get_config(win).zindex
  if
    not zindex
    or vim.api.nvim_win_get_config(backdrop).zindex ~= zindex - 1
    or vim.bo[vim.api.nvim_win_get_buf(backdrop)].filetype ~= "snacks_win_backdrop"
  then
    return nil
  end
  return {
    win = backdrop,
    close = function(self)
      local closing = self.win
      self.win = nil
      if closing and vim.api.nvim_win_is_valid(closing) then
        local closing_buf = vim.api.nvim_win_get_buf(closing)
        pcall(vim.api.nvim_win_close, closing, true)
        pcall(vim.api.nvim_buf_delete, closing_buf, { force = true })
      end
    end,
  }
end

---The window that an adoption takes for the terminal's: a window that shows the buffer and that Snacks made for it (it
---carries the `snacks_win` marker, which a window shown by `nvim_win_set_buf` does not, such as the copy that a diff tab
---shows). A marked window of the current tab comes first, then a marked one of another tab (as an instance that
---`snacks` started tracks the window that it showed, in whichever tab), then an unmarked one of the current tab (a split
---that an older version re-created). An unmarked window of another tab is a copy and counts for nothing. Later entries
---keep the window that the instance tracks, so a hide and a show never mistake a copy for the terminal's window.
---@param buf number
---@return number|nil win
local function find_window(buf)
  local tab = vim.api.nvim_get_current_tabpage()
  local best, best_rank
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local here = vim.api.nvim_win_get_tabpage(win) == tab
    local marked = vim.w[win].snacks_win ~= nil
    local rank = (marked and here and 1) or (marked and 2) or (here and 3) or nil
    if rank and (not best_rank or rank < best_rank) then
      best, best_rank = win, rank
    end
  end
  return best
end

---The options of the Snacks window that wraps an adopted terminal. The window options are what the terminal started
---with, from its buffer variable (the entry's config decides for an older version, which wrote none), and the keys are
---the entry's, as at a start: a key holds a function, which a buffer variable cannot keep.
---@param buf number
---@param config table|nil
---@return table win_opts
local function wrapper_options(buf, config)
  local built = build_opts(config or {}, {}, true).win
  local stored = vim.b[buf][WINDOW_VAR]
  local win_opts
  if type(stored) == "table" then
    win_opts = plain(stored)
  else
    -- An older version stored nothing. Snacks.terminal.open gives a split the winbar below.
    win_opts = plain(built)
    win_opts.wo = win_opts.wo or {}
    win_opts.wo.winbar = win_opts.position == "float" and "" or "1: %{get(b:, 'term_title', '')}"
  end
  win_opts.keys = built.keys
  -- The anchor of a float that is relative to a window. Without one, Snacks takes the window that is current when it
  -- creates the wrapper, so keep the stored one while it exists, and drop one that is gone (the window closed).
  if win_opts.win ~= nil and not (type(win_opts.win) == "number" and vim.api.nvim_win_is_valid(win_opts.win)) then
    win_opts.win = nil
  end
  win_opts.buf, win_opts.show = buf, false
  -- The terminal style gives the keys of a Snacks terminal (q hides it). Without it, the generic `q = "close"` would
  -- wipe the buffer and stop Claude.
  win_opts.style = "terminal"
  return win_opts
end

---A Snacks instance for the Claude that an earlier copy of this module started (before a reload). The Claude buffer
---keeps its mark, but Snacks.terminal.list() cannot hand out its instance: Snacks keys an instance by its command,
---directory, env and count, and clears the key when any buffer with that key is wiped, so it can lose a running Claude.
---So this wraps the buffer in a new Snacks window with the window options that the terminal started with, and shows no
---window of its own. A split or a float then comes back the way it started. The keys of the buffer close over the
---instance that started the Claude, and a hide or a show on the wrapper would leave that one with a stale window, so
---the wrapper maps its own keys over them, once an entry brings the config that has the user's keys.
---@param buf number
---@param config table|nil
---@return table instance
local function wrap_terminal(buf, config)
  local instance = Snacks.win(wrapper_options(buf, config))
  -- The style sets a filetype, and the stored window options can hold `bo` too (a start of this version stores the `bo` of
  -- its instance, and an older version's options are built from the config). The buffer has its own filetype already,
  -- and Snacks sets `bo` on the buffer again on every VimResized, which would fire FileType again. So the reset runs
  -- right after the constructor.
  instance.opts.bo = {}
  -- Snacks sets `buf` when it shows an instance. This one shows no window of its own, so set it here. Snacks wipes the
  -- buffer of a scratch instance when it closes, and this terminal buffer was started by Snacks.terminal.
  instance.buf, instance.scratch_buf = buf, buf
  patch_instance(instance, adopted_config(buf, config))
  instance.adopted = true
  instance._cc.configless = config == nil
  instance.win = find_window(buf)
  instance.backdrop = find_backdrop(instance.win, buf)
  -- Only an entry with a config knows the user's keys, and only a hide or a show needs the maps of the wrapper. A map
  -- without the config would turn on a key that the user turned off (Snacks never removes a map), so the entry that
  -- brings a config maps them (upgrade_wrapper).
  if config then
    instance:map()
  end
  return instance
end

---Gives an adopted instance that an entry without a config wrapped the options that a config brings: the keys (the
---style's and the user's, mapped now), and the window options of a terminal that an older version started.
---@param instance table
---@param config table
local function upgrade_wrapper(instance, config)
  local fresh = Snacks.win(wrapper_options(instance.buf, config))
  fresh.opts.bo = {}
  instance.opts, instance.keys = fresh.opts, fresh.keys
  instance._cc.configless = false
  instance:map()
end

---Forgets a tracked terminal whose Claude exited. When no terminal is tracked then, tracks the Claude that an earlier
---copy of this module started (before a reload): its buffer keeps its mark, and a live job shows that it still runs. A
---window may or may not show it.
---@param config table|nil The config of the entry, when it has one
local function adopt_existing_terminal(config)
  -- The entry's config first: an older version wrote no auto_close, and forget_ended_terminal needs the entry's.
  if config and terminal and terminal.adopted and terminal:buf_valid() then
    terminal._cc.config = adopted_config(terminal.buf, config)
    if terminal._cc.configless then
      upgrade_wrapper(terminal, config)
    end
  end
  forget_ended_terminal()
  if terminal and terminal:buf_valid() then
    return
  end
  -- A terminal gets its mark only after its start succeeded, so the one that M.open is starting is not adopted here.
  if not is_available() then
    return
  end
  local buf = owned.find(OWNED_MARK)
  if buf then
    terminal = wrap_terminal(buf, config)
    require("claudecode.logger").debug("terminal", "Recovered existing Claude terminal in buffer", buf)
  end
end

---Stops a Claude that the native provider started before a reload. The provider choice changed since, so nothing
---controls that Claude, and it would run beside the one that this provider starts.
---@return boolean stopped
local function stop_native_terminal()
  if not owned.stop_other(owned.NATIVE_MARK, "native") then
    return false
  end
  vim.notify(
    "Stopped the Claude that the native provider started, because the snacks provider is in use.",
    vim.log.levels.WARN
  )
  return true
end

function M.setup()
  -- No specific setup needed for Snacks provider
end

---Open a terminal using Snacks.nvim
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
---@param focus boolean?
function M.open(cmd_string, env_table, config, focus)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  focus = utils.normalize_focus(focus)

  adopt_existing_terminal(config)

  if terminal and terminal:buf_valid() then
    -- Reuse the existing terminal. Route through cc_show so a hidden terminal is
    -- restored without Snacks destroying+recreating the window (which would climb
    -- Claude's cursor -- #240/#183). cc_show honors config.auto_insert (#232).
    cc_show(terminal, focus, config)
    return
  end

  -- A BufEnter or TermOpen autocmd can call open while Snacks.terminal.open runs below. That start is the one this
  -- open would begin, so a second start would run a second Claude that nothing tracks.
  if starting then
    return
  end

  -- The stop waits for the job to exit, which runs scheduled callbacks. An open() among them starts Claude, and this
  -- open shows it.
  if stop_native_terminal() and terminal and terminal:buf_valid() then
    cc_show(terminal, focus, config)
    return
  end

  local opts = build_opts(config, env_table, focus)
  -- Pass an argv list (not a string) so Snacks spawns Claude via termopen()
  -- without a shell. A shell would glob-expand bracketed model aliases like
  -- "opus[1m]" (e.g. zsh aborts with "no matches found"). parse_command keeps
  -- quoted arguments intact and expands a leading "~". Mirrors native.
  local cmd = utils.parse_command(cmd_string)
  -- Snacks shows its window before it calls termopen, and termopen raises for a
  -- command that is not executable. Capture the instance so that window can be closed.
  local shown_instance
  local user_on_buf = opts.win.on_buf
  opts.win.on_buf = function(instance)
    shown_instance = instance
    if user_on_buf then
      user_on_buf(instance)
    end
  end
  starting = true
  local opened, open_result = pcall(Snacks.terminal.open, cmd, opts)
  starting = false
  local term_instance = opened and open_result or nil
  -- When errors are silenced, termopen returns -1 instead of raising and leaves a plain buffer.
  local started = term_instance
    and term_instance:buf_valid()
    and vim.api.nvim_buf_get_option(term_instance.buf, "buftype") == "terminal"
  if started then
    setup_terminal_events(term_instance, config)
    patch_instance(term_instance, config)
    vim.b[term_instance.buf][OWNED_MARK] = true
    vim.b[term_instance.buf][AUTO_CLOSE_VAR] = config.auto_close and true or false
    -- The resolved options of the instance (the terminal style, position, size, window options), not the ones passed.
    local window = plain(term_instance.opts or opts.win)
    -- `keys` holds a table that mixes list and map keys, which a buffer variable cannot keep (E5100), and the wrapper
    -- builds its own keys. `plain` has dropped the functions already, and the wrapper resets `bo` after its constructor.
    window.keys = nil
    -- Only a float that is relative to a window has an anchor. The wrapper keeps it while that window exists.
    if window.relative ~= "win" then
      window.win = nil
    end
    -- A table that mixes list and map keys cannot be stored. The adoption then uses the entry's config.
    pcall(function()
      vim.b[term_instance.buf][WINDOW_VAR] = window
    end)
    remember_backdrop(term_instance)
    if not focus then
      -- Snacks keeps these opts for every later show.
      term_instance.opts.enter = (config.snacks_win_opts or {}).enter
    end
    -- Snacks.terminal.open has already fired FileType, so a <C-z> mapping that a user's handler set stays.
    utils.map_terminal_suspend(term_instance.buf)
    terminal = term_instance
  else
    terminal = nil
    local logger = require("claudecode.logger")
    local error_details = {}
    if not opened then
      table.insert(error_details, tostring(open_result):match("^[^\n]*"))
    elseif not term_instance then
      table.insert(error_details, "Snacks.terminal.open() returned nil")
    elseif not term_instance:buf_valid() then
      table.insert(error_details, "terminal instance is invalid")
      if term_instance.buf and not vim.api.nvim_buf_is_valid(term_instance.buf) then
        table.insert(error_details, "buffer is invalid")
      end
      if term_instance.win and not vim.api.nvim_win_is_valid(term_instance.win) then
        table.insert(error_details, "window is invalid")
      end
    else
      table.insert(error_details, "no terminal job started")
    end

    local leftover = term_instance or shown_instance
    if leftover then
      leftover:close({ buf = true })
    end

    local error_msg = string.format(
      "Failed to open Claude terminal using Snacks. Details: %s. Context: cmd='%s'",
      table.concat(error_details, ", "),
      cmd_string
    )
    vim.notify(error_msg, vim.log.levels.ERROR)
    -- env values can be user secrets, so the log names only the env keys.
    local env_keys = vim.tbl_keys(opts.env or {})
    table.sort(env_keys)
    logger.debug("terminal", error_msg .. ", opts=" .. vim.inspect(vim.tbl_extend("force", opts, { env = env_keys })))
  end
end

---Close the terminal
function M.close()
  if not is_available() then
    return
  end
  adopt_existing_terminal()
  if not (terminal and terminal:buf_valid()) then
    -- A Claude that the other provider started before a reload runs on, and nothing else stops it.
    stop_native_terminal()
    return
  end
  local closing = terminal
  local closing_bufnr = closing.buf
  local jobid = vim.bo[closing_bufnr].channel
  -- The wait below runs scheduled callbacks. An open() among them must start a new terminal, not reuse this one.
  terminal = nil

  -- Snacks wipes the buffer on close. Deleting a terminal buffer while a write to its job is pending hangs
  -- Neovim (neovim/neovim#42508), so stop the job first and wait for TermClose. The wait runs the event loop.
  -- A job that reads its input, like Claude, takes the pending writes there and exits. A job that stopped
  -- reading (for example `yes`, or `cat` after a large multi-line send) keeps them pending, the wait times
  -- out, and Neovim can still hang once the buffer is wiped. This code does not prevent that.
  -- An exited Claude (auto_close = false) has nothing to wait for.
  if jobid > 0 and vim.fn.jobwait({ jobid }, 0)[1] == -1 then
    closing._cc.closing = true
    if closing.adopted then
      -- The TermClose handler belongs to the instance that started this Claude, and it cannot see `closing` on this
      -- one. Without the mark it does not report the stop as a failure.
      vim.b[closing_bufnr][OWNED_MARK] = nil
    end
    local exited = false
    vim.api.nvim_create_autocmd("TermClose", {
      buffer = closing_bufnr,
      once = true,
      callback = function()
        exited = true
      end,
    })
    vim.fn.jobstop(jobid)
    -- The auto_close handler or a user's TermClose autocmd can wipe the buffer first.
    vim.wait(1000, function()
      return exited or not vim.api.nvim_buf_is_valid(closing_bufnr)
    end, 10)
  end
  if closing:buf_valid() then
    closing:close()
  end
end

---Simple toggle: always show/hide terminal regardless of focus
---@param cmd_string string
---@param env_table table
---@param config table
function M.simple_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")

  adopt_existing_terminal(config)
  if terminal and terminal:buf_valid() then
    if cc_is_visible(terminal) then
      logger.debug("terminal", "Simple toggle: hiding visible terminal")
      cc_hide(terminal)
    else
      logger.debug("terminal", "Simple toggle: showing hidden terminal")
      cc_show(terminal, true, config)
    end
  else
    logger.debug("terminal", "Simple toggle: creating new terminal")
    M.open(cmd_string, env_table, config)
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused
---@param cmd_string string
---@param env_table table
---@param config table
function M.focus_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")

  adopt_existing_terminal(config)
  if terminal and terminal:buf_valid() then
    if not cc_is_visible(terminal) then
      -- Terminal exists but is hidden -> show and focus it.
      logger.debug("terminal", "Focus toggle: showing hidden terminal")
      cc_show(terminal, true, config)
    elseif terminal.win == vim.api.nvim_get_current_win() then
      -- You're IN it -> hide it.
      logger.debug("terminal", "Focus toggle: hiding terminal (currently focused)")
      cc_hide(terminal)
    else
      -- Visible but not focused -> focus it.
      logger.debug("terminal", "Focus toggle: focusing terminal")
      vim.api.nvim_set_current_win(terminal.win)
      maybe_start_insert(terminal, config)
    end
  else
    logger.debug("terminal", "Focus toggle: creating new terminal")
    M.open(cmd_string, env_table, config)
  end
end

---Legacy toggle function for backward compatibility (defaults to simple_toggle)
---@param cmd_string string
---@param env_table table
---@param config table
function M.toggle(cmd_string, env_table, config)
  M.simple_toggle(cmd_string, env_table, config)
end

---Get the active terminal buffer number
---@return number?
function M.get_active_bufnr()
  adopt_existing_terminal()
  if terminal and terminal:buf_valid() and terminal.buf then
    if vim.api.nvim_buf_is_valid(terminal.buf) then
      return terminal.buf
    end
  end
  return nil
end

---Hide the terminal when it is a visible float, so that it does not cover a diff. A split stays as it is: a
---diff makes room for it. With `tab`, a float in another tab stays too.
---@param tab number? Hide the float only when it is in this tab. Any tab when nil.
---@return boolean hidden Whether a float was hidden
function M.hide_float(tab)
  if not (terminal and terminal:buf_valid() and cc_is_visible(terminal) and win_is_floating(terminal.win)) then
    return false
  end
  if tab ~= nil and vim.api.nvim_win_get_tabpage(terminal.win) ~= tab then
    return false
  end
  cc_hide(terminal)
  return true
end

---Is the terminal provider available?
---@return boolean
function M.is_available()
  return is_available()
end

---For testing purposes
---@return table? terminal The terminal instance, or nil
function M._get_terminal_for_test()
  return terminal
end

---@type ClaudeCodeTerminalProvider
return M

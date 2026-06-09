---Snacks.nvim terminal provider for Claude Code.
---@module 'claudecode.terminal.snacks'

local M = {}

local snacks_available, Snacks = pcall(require, "snacks")
local utils = require("claudecode.utils")
local terminal = nil

--- @return boolean
local function is_available()
  return snacks_available and Snacks and Snacks.terminal ~= nil
end

---Setup event handlers for terminal instance
---@param term_instance table The Snacks terminal instance
---@param config table Configuration options
local function setup_terminal_events(term_instance, config)
  local logger = require("claudecode.logger")

  -- Handle command completion/exit - only if auto_close is enabled
  if config.auto_close then
    term_instance:on("TermClose", function()
      if vim.v.event.status ~= 0 then
        logger.error("terminal", "Claude exited with code " .. vim.v.event.status .. ".\nCheck for any errors.")
      end

      -- Clean up
      terminal = nil
      vim.schedule(function()
        term_instance:close({ buf = true })
        vim.cmd.checktime()
      end)
    end, { buf = true })
  end

  -- Handle buffer deletion
  term_instance:on("BufWipeout", function()
    logger.debug("terminal", "Terminal buffer wiped")
    terminal = nil
  end, { buf = true })
end

---Builds Snacks terminal options with focus control
---@param config ClaudeCodeTerminalConfig Terminal configuration
---@param env_table table Environment variables to set for the terminal process
---@param focus boolean|nil Whether to focus the terminal when opened (defaults to true)
---@return snacks.terminal.Opts opts Snacks terminal options with start_insert/auto_insert controlled by focus parameter
local function build_opts(config, env_table, focus)
  focus = utils.normalize_focus(focus)
  return {
    env = env_table,
    cwd = config.cwd,
    start_insert = focus,
    auto_insert = focus,
    auto_close = false,
    win = vim.tbl_deep_extend("force", {
      position = config.split_side,
      width = config.split_width_percentage,
      height = 0,
      relative = "editor",
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
      start_insert_if_terminal(term)
    end
    return true
  end

  -- Already visible -> optionally focus.
  if cc_is_visible(term) then
    if focus then
      vim.api.nvim_set_current_win(term.win)
      start_insert_if_terminal(term)
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
    term._cc.orig_show(term)
    if focus and term.win and vim.api.nvim_win_is_valid(term.win) then
      vim.api.nvim_set_current_win(term.win)
      start_insert_if_terminal(term)
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
  vim.api.nvim_win_set_buf(new_win, term.buf)
  if not horizontal then
    vim.api.nvim_win_set_height(new_win, vim.o.lines) -- full height for vertical splits, like native
  end
  term.closed = false
  reapply_snacks_window_state(term, new_win)
  if focus then
    start_insert_if_terminal(term)
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

  if terminal and terminal:buf_valid() then
    -- Reuse the existing terminal. Route through cc_show so a hidden terminal is
    -- restored without Snacks destroying+recreating the window (which would climb
    -- Claude's cursor -- #240/#183).
    cc_show(terminal, focus, config)
    return
  end

  local opts = build_opts(config, env_table, focus)
  -- Pass an argv list (not a string) so Snacks spawns Claude via termopen()
  -- without a shell. A shell would glob-expand bracketed model aliases like
  -- "opus[1m]" (e.g. zsh aborts with "no matches found"). parse_command keeps
  -- quoted arguments intact and expands a leading "~". Mirrors native.
  local cmd = utils.parse_command(cmd_string)
  local term_instance = Snacks.terminal.open(cmd, opts)
  if term_instance and term_instance:buf_valid() then
    setup_terminal_events(term_instance, config)
    patch_instance(term_instance, config)
    terminal = term_instance
  else
    terminal = nil
    local logger = require("claudecode.logger")
    local error_details = {}
    if not term_instance then
      table.insert(error_details, "Snacks.terminal.open() returned nil")
    elseif not term_instance:buf_valid() then
      table.insert(error_details, "terminal instance is invalid")
      if term_instance.buf and not vim.api.nvim_buf_is_valid(term_instance.buf) then
        table.insert(error_details, "buffer is invalid")
      end
      if term_instance.win and not vim.api.nvim_win_is_valid(term_instance.win) then
        table.insert(error_details, "window is invalid")
      end
    end

    local context = string.format("cmd='%s', opts=%s", cmd_string, vim.inspect(opts))
    local error_msg = string.format(
      "Failed to open Claude terminal using Snacks. Details: %s. Context: %s",
      table.concat(error_details, ", "),
      context
    )
    vim.notify(error_msg, vim.log.levels.ERROR)
    logger.debug("terminal", error_msg)
  end
end

---Close the terminal
function M.close()
  if not is_available() then
    return
  end
  if terminal and terminal:buf_valid() then
    terminal:close()
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
      start_insert_if_terminal(terminal)
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
  if terminal and terminal:buf_valid() and terminal.buf then
    if vim.api.nvim_buf_is_valid(terminal.buf) then
      return terminal.buf
    end
  end
  return nil
end

---Is the terminal provider available?
---@return boolean
function M.is_available()
  return is_available()
end

---Reposition the terminal window using new config, keeping the terminal process alive.
---Closes the current window (not the buffer), then reopens with new position/opts.
---@param cmd_string string
---@param env_table table
---@param config table
function M.reposition(cmd_string, env_table, config)
  if not is_available() or not terminal or not terminal:buf_valid() then
    return
  end
  local buf = terminal.buf
  terminal:close({ buf = false })
  local opts = build_opts(config, env_table, true)
  opts.win.buf = buf
  local new_term = Snacks.win(opts.win)
  if new_term and new_term:buf_valid() then
    terminal = new_term
  end
end

---For testing purposes
---@return table? terminal The terminal instance, or nil
function M._get_terminal_for_test()
  return terminal
end

---@type ClaudeCodeTerminalProvider
return M

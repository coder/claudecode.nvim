-- HideNoError: with the native provider, a BufEnter or TermOpen autocmd that calls focus_toggle (or simple_toggle twice,
-- or closes the window) while open_terminal runs makes the start raise "Invalid window id" at native.lua:263, because
-- focus_toggle adopts the half-started terminal and hides its new window. Claude runs with no window.
-- Path: you open Claude (native); the autocmd closes the new split (a BufEnter before termopen, a TermOpen inside it);
-- the start goes on. Fixed in #527: Claude runs hidden and tracked, and a toggle shows it. A hide, then a show in
-- another window, leaves Claude visible, focused, and closed with its job (auto_close). With 'nohidden', a window that closes
-- during the start unloads a buffer that is not bufhidden=hide: on Neovim 0.8 a BufEnter close started a second, bare claude,
-- and a TermOpen hide ended Claude. The buffer is bufhidden=hide before it has a window now. A BUG line means the finding is back.
local lib = dofile(os.getenv("REPLAY_LIB"))

local function first_line(text)
  return (tostring(text):gsub("\n.*", ""))
end

local errors = {}
vim.notify = function(msg, level)
  if level ~= nil and level >= vim.log.levels.ERROR then
    table.insert(errors, first_line(msg))
  end
end

local actions = {
  {
    name = "calls focus_toggle",
    run = function(term)
      term.focus_toggle()
    end,
  },
  {
    name = "calls simple_toggle twice",
    run = function(term)
      term.simple_toggle()
      term.simple_toggle()
    end,
  },
  {
    name = "closes the window",
    run = function()
      vim.api.nvim_win_close(vim.api.nvim_get_current_win(), false)
    end,
  },
}

for _, event in ipairs({ "BufEnter", "TermOpen" }) do
  for _, action in ipairs(actions) do
    local label = string.format("native, a %s autocmd %s during the start", event, action.name)
    lib.attempt(label, function()
      errors = {}
      local term = lib.reload(function()
        local terminal = require("claudecode.terminal")
        terminal.setup({ provider = "native", auto_close = true, auto_insert = false }, "sh -c 'sleep 60'")
        return terminal
      end)
      local group = vim.api.nvim_create_augroup("start_autocmd_hide", { clear = true })
      local fired = 0
      vim.api.nvim_create_autocmd(event, {
        group = group,
        callback = function(ev)
          -- Only the start buffer: it is a plain buffer on BufEnter (before termopen) and a terminal on TermOpen.
          if fired == 0 and ev.buf ~= 1 then
            fired = fired + 1
            local ok, err = pcall(action.run, term)
            if not ok then
              table.insert(errors, "the autocmd raised: " .. first_line(err))
            end
          end
        end,
      })
      local opened, open_err = pcall(term.open)
      lib.settle()
      vim.api.nvim_del_augroup_by_id(group)
      local running = lib.running()
      local shown = 0
      for _, buf in ipairs(running) do
        shown = shown + lib.windows_showing(buf)
      end
      lib.step(
        string.format(
          "%s: open %s, fired %d, %d Claude running, %d window(s) show it, messages: %s",
          label,
          opened and "ok" or ("RAISED " .. first_line(open_err)),
          fired,
          #running,
          shown,
          #errors > 0 and table.concat(errors, " | ") or "none"
        ),
        (not opened) or fired ~= 1 or #running ~= 1 or #errors > 0
      )
      -- The next toggle shows the terminal that no window shows, and starts no second one.
      if #running == 1 then
        pcall(term.simple_toggle)
        lib.settle()
        local again = lib.running()
        lib.step(
          string.format(
            "%s: a toggle afterwards leaves %d Claude running, %d window(s) show it",
            label,
            #again,
            #again == 1 and lib.windows_showing(again[1]) or 0
          ),
          #again ~= 1 or lib.windows_showing(again[1]) ~= 1
        )
      end
      for _, buf in ipairs(lib.running()) do
        vim.b[buf].claudecode_native_terminal = nil
        pcall(vim.fn.jobstop, vim.bo[buf].channel)
      end
      lib.wait(300)
      vim.cmd("silent! only")
      vim.cmd("silent! %bwipeout!")
    end)
  end
end

-- A later autocmd of the start shows the terminal again, in a window of its own. That is the window of Claude: the start
-- focuses it, and the exit of the job closes it with auto_close.
for _, event in ipairs({ "BufEnter", "TermOpen" }) do
  local label = string.format("native, a %s autocmd hides the terminal and shows it again during the start", event)
  lib.attempt(label, function()
    errors = {}
    local term = lib.reload(function()
      local terminal = require("claudecode.terminal")
      terminal.setup({ provider = "native", auto_close = true, auto_insert = false }, "sh -c 'sleep 60'")
      return terminal
    end)
    local group = vim.api.nvim_create_augroup("start_autocmd_show", { clear = true })
    local fired = 0
    vim.api.nvim_create_autocmd(event, {
      group = group,
      callback = function(ev)
        if fired == 0 and ev.buf ~= 1 then
          fired = fired + 1
          local ok, err = pcall(function()
            term.simple_toggle() -- adopts the terminal that starts
            term.simple_toggle() -- hides it
            term.simple_toggle() -- shows it in another window
          end)
          if not ok then
            table.insert(errors, "the autocmd raised: " .. first_line(err))
          end
        end
      end,
    })
    local opened, open_err = pcall(term.open)
    lib.settle()
    vim.api.nvim_del_augroup_by_id(group)
    local running = lib.running()
    local shown = #running == 1 and lib.windows_showing(running[1]) or 0
    local focused = #running == 1 and vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) == running[1]
    lib.step(
      string.format(
        "%s: open %s, %d Claude running, %d window(s) show it, you are in it: %s, messages: %s",
        label,
        opened and "ok" or ("RAISED " .. first_line(open_err)),
        #running,
        shown,
        tostring(focused),
        #errors > 0 and table.concat(errors, " | ") or "none"
      ),
      (not opened) or #running ~= 1 or shown ~= 1 or not focused or #errors > 0
    )
    -- The job exits on its own with auto_close: its window closes.
    if #running == 1 then
      local buf = running[1]
      pcall(vim.fn.jobstop, vim.bo[buf].channel)
      lib.wait(500)
      local still_shown = vim.api.nvim_buf_is_valid(buf) and lib.windows_showing(buf) or 0
      lib.step(
        string.format("%s: after the job exits, %d window(s) still show it", label, still_shown),
        still_shown ~= 0
      )
    end
    for _, buf in ipairs(lib.running()) do
      vim.b[buf].claudecode_native_terminal = nil
      pcall(vim.fn.jobstop, vim.bo[buf].channel)
    end
    lib.wait(300)
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
  end)
end

-- With 'nohidden', a window that closes during the start unloads a buffer that is not bufhidden=hide. Before termopen,
-- Neovim loads it again, and on 0.8 its term:// reader starts a second terminal in it (a bare `claude`, with no
-- arguments, which then gets the sends). In TermOpen the unload ends Claude with a "Failed to open" error.
-- Claude here is a script named claude on PATH. It logs each start, so that a second one (a bare `claude`) shows.
for _, event in ipairs({ "BufEnter", "TermOpen" }) do
  local label = string.format(
    "native, 'nohidden', a %s autocmd %s during the start",
    event,
    event == "BufEnter" and "closes the split" or "calls focus_toggle"
  )
  lib.attempt(label, function()
    errors = {}
    local log = vim.fn.tempname()
    local bin = vim.fn.tempname()
    vim.fn.mkdir(bin, "p")
    local script = assert(io.open(bin .. "/claude", "w"))
    script:write(string.format('#!/bin/sh\necho "started args=[$*]" >> %s\nexec sleep 60\n', vim.fn.shellescape(log)))
    script:close()
    vim.loop.fs_chmod(bin .. "/claude", 493)
    local path = vim.env.PATH
    vim.env.PATH = bin .. ":" .. path
    local term = lib.reload(function()
      local terminal = require("claudecode.terminal")
      terminal.setup({ provider = "native", auto_close = true, auto_insert = false }, "claude --model x")
      return terminal
    end)
    local hidden = vim.o.hidden
    vim.o.hidden = false
    local group = vim.api.nvim_create_augroup("start_autocmd_nohidden", { clear = true })
    local fired = 0
    vim.api.nvim_create_autocmd(event, {
      group = group,
      callback = function(ev)
        if fired == 0 and ev.buf ~= 1 then
          fired = fired + 1
          local ok, err = pcall(function()
            if event == "BufEnter" then
              vim.cmd("close")
            else
              term.focus_toggle()
            end
          end)
          if not ok then
            table.insert(errors, "the autocmd raised: " .. first_line(err))
          end
        end
      end,
    })
    local opened, open_err = pcall(term.open)
    lib.wait(600)
    vim.api.nvim_del_augroup_by_id(group)
    vim.o.hidden = hidden
    vim.env.PATH = path
    local starts = 0
    local fh = io.open(log, "r")
    if fh then
      for _ in fh:lines() do
        starts = starts + 1
      end
      fh:close()
    end
    local running = lib.running()
    lib.step(
      string.format(
        "%s: open %s, fired %d, %d start(s) of Claude, %d running, messages: %s",
        label,
        opened and "ok" or ("RAISED " .. first_line(open_err)),
        fired,
        starts,
        #running,
        #errors > 0 and table.concat(errors, " | ") or "none"
      ),
      (not opened) or fired ~= 1 or starts ~= 1 or #running ~= 1 or #errors > 0
    )
    os.remove(log)
    vim.fn.delete(bin, "rf")
    for _, buf in ipairs(lib.running()) do
      vim.b[buf].claudecode_native_terminal = nil
      pcall(vim.fn.jobstop, vim.bo[buf].channel)
    end
    lib.wait(300)
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
  end)
end
lib.finish()

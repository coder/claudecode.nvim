-- AtMostOneClaude, and a start that an autocmd interrupts. The vsplit of a native start fires WinLeave, WinNew and WinEnter,
-- and creating the buffer fires BufNew and BufAdd, all before the plugin has marked a buffer for Claude. An entry that such
-- an autocmd calls found no terminal to adopt and started a second Claude, and a close returned with one still running.
-- Fixed: open_terminal returns while a start runs, so that start makes the one Claude. The vsplit keeps every autocmd of
-- yours, so an autosave on WinLeave still saves the file before Claude starts. A close() that a BufEnter or TermOpen autocmd
-- calls runs when the start returns, because it cannot wait for the job inside termopen (on Neovim 0.8 that aborts the editor).
local lib = dofile(os.getenv("REPLAY_LIB"))

local function first_line(text)
  return (tostring(text):gsub("\n.*", ""))
end

local errors = {}
vim.notify = function(msg, level)
  if level ~= nil and level >= vim.log.levels.WARN then
    table.insert(errors, first_line(msg))
  end
end

local function fresh()
  errors = {}
  return lib.reload(function()
    local terminal = require("claudecode.terminal")
    terminal.setup({ provider = "native", auto_close = true, auto_insert = false }, "sh -c 'sleep 60'")
    return terminal
  end)
end

local function clean_up()
  for _, buf in ipairs(lib.running()) do
    vim.b[buf].claudecode_native_terminal = nil
    pcall(vim.fn.jobstop, vim.bo[buf].channel)
  end
  lib.wait(300)
  vim.cmd("silent! only")
  vim.cmd("silent! %bwipeout!")
end

-- Run `action(term)` once, from the first `event`.
local function arm(event, term, action)
  local group = vim.api.nvim_create_augroup("start_reentry", { clear = true })
  local fired = 0
  vim.api.nvim_create_autocmd(event, {
    group = group,
    callback = function()
      if fired == 0 then
        fired = fired + 1
        local ok, err = pcall(action, term)
        if not ok then
          table.insert(errors, "the autocmd raised: " .. first_line(err))
        end
      end
    end,
  })
  return function()
    vim.api.nvim_del_augroup_by_id(group)
    return fired
  end
end

-- An entry that an early autocmd of the start calls does nothing. One Claude, tracked, shown in one window.
for _, event in ipairs({ "WinLeave", "WinNew", "WinEnter", "BufNew", "BufAdd" }) do
  for _, entry in ipairs({ "open", "simple_toggle", "focus_toggle" }) do
    local label = string.format("native, a %s autocmd that calls %s during the start", event, entry)
    lib.attempt(label, function()
      local term = fresh()
      local disarm = arm(event, term, function(t)
        t[entry]()
      end)
      local opened, open_err = pcall(term.open)
      lib.settle()
      local fired = disarm()
      local running = lib.running()
      local tracked = term.get_active_terminal_bufnr()
      local shown = #running >= 1 and lib.windows_showing(running[1]) or 0
      lib.step(
        string.format(
          "%s: open %s, fired %d, %d Claude running, tracked %s, %d window(s) show the first, messages: %s",
          label,
          opened and "ok" or ("RAISED " .. first_line(open_err)),
          fired,
          #running,
          tostring(tracked),
          shown,
          #errors > 0 and table.concat(errors, " | ") or "none"
        ),
        (not opened) or fired ~= 1 or #running ~= 1 or tracked ~= running[1] or shown ~= 1 or #errors > 0
      )
      clean_up()
    end)
  end
end

-- Your WinLeave autosave runs for the vsplit, so the file on disk has your edit when Claude starts.
lib.attempt("native, an autosave on WinLeave saves the file before Claude starts", function()
  local term = fresh()
  local path = vim.fn.getcwd() .. "/autosave-file.txt"
  vim.fn.writefile({ "old text" }, path)
  vim.cmd("edit " .. path)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "new text the user typed" })
  vim.api.nvim_create_autocmd("WinLeave", { group = vim.api.nvim_create_augroup("start_reentry_save", { clear = true }), command = "silent! update" })
  local opened, open_err = pcall(term.open)
  lib.settle()
  vim.api.nvim_del_augroup_by_name("start_reentry_save")
  local on_disk = vim.fn.readfile(path)[1]
  lib.step(
    string.format(
      "native, an autosave on WinLeave saves the file before Claude starts: open %s, on disk [%s], messages: %s",
      opened and "ok" or ("RAISED " .. first_line(open_err)),
      tostring(on_disk),
      #errors > 0 and table.concat(errors, " | ") or "none"
    ),
    (not opened) or on_disk ~= "new text the user typed"
  )
  vim.fn.delete(path)
  clean_up()
end)

-- A close() from an autocmd of the start. The start ends, and Claude stops.
for _, event in ipairs({ "BufEnter", "TermOpen" }) do
  local label = string.format("native, a %s autocmd calls close during the start", event)
  lib.attempt(label, function()
    local term = fresh()
    local disarm = arm(event, term, function(t)
      t.close()
    end)
    local opened, open_err = pcall(term.open)
    lib.wait(1200)
    local fired = disarm()
    local running = lib.running()
    lib.step(
      string.format(
        "%s: open %s, fired %d, %d Claude running, messages: %s",
        label,
        opened and "ok" or ("RAISED " .. first_line(open_err)),
        fired,
        #running,
        #errors > 0 and table.concat(errors, " | ") or "none"
      ),
      (not opened) or fired ~= 1 or #running ~= 0 or #errors > 0
    )
    clean_up()
  end)
end

-- An autocmd of yours changes bufhidden after the start (a TermEnter autocmd that sets wipe). The next hide closes Claude's
-- window, which would then end Claude. A hide sets bufhidden=hide again, so Claude runs on and the next toggle shows it.
lib.attempt("native, bufhidden is wipe when you hide Claude", function()
  local term = fresh()
  local opened, open_err = pcall(term.open)
  lib.settle()
  local buf = term.get_active_terminal_bufnr()
  if buf then
    vim.bo[buf].bufhidden = "wipe"
  end
  local hid, hide_err = pcall(term.simple_toggle)
  lib.wait(300)
  local running = lib.running()
  local still_tracked = term.get_active_terminal_bufnr() == buf
  local shown_before = #running == 1 and lib.windows_showing(running[1]) or -1
  pcall(term.simple_toggle)
  lib.settle()
  local again = lib.running()
  local shown_after = #again == 1 and lib.windows_showing(again[1]) or -1
  lib.step(
    string.format(
      "native, bufhidden is wipe when you hide Claude: open %s, hide %s, %d Claude running, %d window(s) show it, tracked: %s, after the next toggle %d window(s) show it, messages: %s",
      opened and "ok" or ("RAISED " .. first_line(open_err)),
      hid and "ok" or ("RAISED " .. first_line(hide_err)),
      #running,
      shown_before,
      tostring(still_tracked),
      shown_after,
      #errors > 0 and table.concat(errors, " | ") or "none"
    ),
    (not opened) or (not hid) or #running ~= 1 or shown_before ~= 0 or not still_tracked or shown_after ~= 1
  )
  clean_up()
end)
lib.finish()

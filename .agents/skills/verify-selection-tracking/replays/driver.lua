-- Replay driver for the verify-selection-tracking probes. Starts the real plugin (the real start path, the real
-- selection.lua with real uv timers), records every selection_changed the server would broadcast, and types keys
-- through the main loop one step at a time. Only server.broadcast is replaced, and only in this process.
-- A probe calls run(opts, steps, verdict): each step is { wait_ms, keys or function, label }; verdict(log, sel)
-- returns ok (boolean) and a one-line description. Neovim exits 0 for OK and 1 for BUG.
local M = {}

local function show(sel)
  if not sel then
    return "nil"
  end
  local s, e = sel.selection.start, sel.selection["end"]
  return string.format(
    "%s %q %d:%d-%d:%d%s",
    vim.fn.fnamemodify(sel.filePath, ":t"),
    sel.text,
    s.line,
    s.character,
    e.line,
    e.character,
    sel.selection.isEmpty and " (cursor)" or ""
  )
end
M.show = show

-- Writes each { name, lines } to a fresh temp dir and opens them, the first one last (so it is current).
-- Returns the paths in order.
function M.files(list)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local paths = {}
  for i = #list, 1, -1 do
    local path = dir .. "/" .. list[i][1]
    vim.fn.writefile(list[i][2], path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    paths[i] = path
  end
  return paths
end

function M.run(opts, steps, verdict)
  local out = {}
  local function say(line)
    table.insert(out, line)
  end
  vim.o.showmode = false
  local claudecode = require("claudecode")
  claudecode.setup(vim.tbl_deep_extend("force", {
    auto_start = false,
    terminal = { provider = "none" },
    log_level = "error",
  }, opts.setup or {}))
  local ok = claudecode.start(false)
  assert(ok, "claudecode.start failed")
  local sent = {}
  require("claudecode.server.init").broadcast = function(method, params)
    if method == "selection_changed" then
      table.insert(sent, vim.deepcopy(params))
      say(string.format("    sent selection_changed: %s", show(params)))
    end
    return true
  end
  local selection = require("claudecode.selection")
  say(
    string.format(
      "nvim %s, debounce_ms=%d, visual_demotion_delay_ms=%d",
      tostring(vim.version()),
      selection.state.debounce_ms,
      selection.state.visual_demotion_delay_ms
    )
  )
  if opts.prepare then
    opts.prepare()
  end
  local i = 0
  local function finish()
    local sel = selection.get_latest_selection()
    local cursor = vim.api.nvim_win_get_cursor(0)
    say(
      string.format(
        "settled: buffer %s, cursor %d:%d, line %q",
        vim.fn.expand("%:t"),
        cursor[1] - 1,
        cursor[2],
        vim.api.nvim_get_current_line()
      )
    )
    say(string.format("Claude holds (getLatestSelection): %s", show(sel)))
    local good, why = verdict(sent, sel)
    say((good and "OK " or "BUG ") .. why)
    say(string.format("%d selection_changed sent, result: %s", #sent, good and "rule holds" or "rule broken"))
    io.stdout:write(table.concat(out, "\n") .. "\n")
    vim.cmd(good and "qa!" or "cquit 1")
  end
  local function step()
    i = i + 1
    local s = steps[i]
    if not s then
      -- Let every timer settle: well past the debounce and the demotion delay.
      vim.defer_fn(finish, 300 + 2 * selection.state.visual_demotion_delay_ms)
      return
    end
    vim.defer_fn(function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      say(
        string.format(
          "  now: mode=%s buf=%s cursor=%d:%d line=%q",
          vim.api.nvim_get_mode().mode,
          vim.fn.expand("%:t"),
          cursor[1] - 1,
          cursor[2],
          vim.api.nvim_get_current_line()
        )
      )
      local keys = s[2]
      say(string.format("+%4dms %s", s[1], s[3] or keys))
      if type(keys) == "function" then
        keys()
      else
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "t", false)
      end
      step()
    end, s[1])
  end
  step()
end

return M

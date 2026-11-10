local function rect(win)
  local pos = vim.api.nvim_win_get_position(win)
  local cfg = vim.api.nvim_win_get_config(win)
  local border = 0
  if type(cfg.border) == "table" then
    for _, part in ipairs(cfg.border) do
      local text = type(part) == "table" and part[1] or part
      if text ~= "" then
        border = 1
      end
    end
  end
  return {
    top = pos[1] - border,
    left = pos[2] - border,
    bottom = pos[1] + vim.api.nvim_win_get_height(win) + border - 1,
    right = pos[2] + vim.api.nvim_win_get_width(win) + border - 1,
  }
end

local function overlap(a, b)
  local height = math.min(a.bottom, b.bottom) - math.max(a.top, b.top) + 1
  local width = math.min(a.right, b.right) - math.max(a.left, b.left) + 1
  if height <= 0 or width <= 0 then
    return 0
  end
  return height * width
end

local current = vim.api.nvim_get_current_win()
local current_buf = vim.api.nvim_win_get_buf(current)
local out = {
  mode = vim.api.nvim_get_mode().mode,
  tabs = #vim.api.nvim_list_tabpages(),
  current_buf = vim.fn.bufname(current_buf),
  current_buftype = vim.bo[current_buf].buftype,
  current_is_float = (vim.api.nvim_win_get_config(current).relative or "") ~= "",
  wins = {},
  covered = {},
}

local floats, diffs = {}, {}
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local cfg = vim.api.nvim_win_get_config(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local entry = {
    win = win,
    name = vim.fn.bufname(buf),
    buftype = vim.bo[buf].buftype,
    float = (cfg.relative or "") ~= "",
    hidden = cfg.hide == true,
    diff = vim.wo[win].diff,
    rect = rect(win),
  }
  out.wins[#out.wins + 1] = entry
  if entry.float and not entry.hidden then
    floats[#floats + 1] = entry
  end
  if entry.diff or entry.name:find("(unified diff)", 1, true) then
    diffs[#diffs + 1] = entry
  end
end

for _, diff_win in ipairs(diffs) do
  local covered = 0
  for _, float in ipairs(floats) do
    covered = math.max(covered, overlap(diff_win.rect, float.rect))
  end
  out.covered[#out.covered + 1] = {
    name = diff_win.name,
    cells = (diff_win.rect.bottom - diff_win.rect.top + 1) * (diff_win.rect.right - diff_win.rect.left + 1),
    covered_cells = covered,
  }
end

out.visible_floats = #floats
out.visible_terminal_floats = #vim.tbl_filter(function(float)
  return float.buftype == "terminal"
end, floats)
out.diff_windows = #diffs
return vim.json.encode(out)

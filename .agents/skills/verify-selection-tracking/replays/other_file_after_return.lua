-- SameFile: with visual_demotion_delay_ms longer than two debounces (here 1000 ms), release a selection in a.txt,
-- go to b.txt and back while the demotion is still pending. Claude must not end up holding b.txt's cursor while
-- you are in a.txt. Before #452 it did. DELAY_MS=50 (the default delay) reruns the same keys.
local driver = require("driver")
local delay = tonumber(os.getenv("DELAY_MS") or "1000")
driver.run({
  setup = { visual_demotion_delay_ms = delay },
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta" } }, { "b.txt", { "one two" } } })
  end,
}, {
  { 50, "ve", "ve (select alpha in a.txt)" },
  { 300, "<Esc>", "<Esc> (release it)" },
  { 250, ":b b.txt<CR>", ":b b.txt" },
  { 250, ":b a.txt<CR>", ":b a.txt (cursor back where it was)" },
}, function(_, sel)
  local here = vim.api.nvim_buf_get_name(0)
  if sel and sel.filePath == here then
    return true, "Claude's selection is in a.txt"
  end
  return false, string.format("you are in a.txt, Claude holds %s", driver.show(sel))
end)

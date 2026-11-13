-- Not a rule, a fact about what a bare `v` and Esc does: with no motion, `v` selects the character under the cursor, so
-- Esc releases a selection of one character, and the plugin sends it. It replaces the selection Claude held before.
-- OK means Claude holds that one character ("a", where the cursor stood after "alpha" was released).
local driver = require("driver")
driver.run({
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta gamma" } } })
  end,
}, {
  { 50, "ve", "select alpha" },
  { 150, "<Esc>", "release alpha" },
  { 300, "v", "v without any motion" },
  { 20, "<Esc>", "Esc without any motion" },
}, function(_, sel)
  return sel and sel.text == "a" and not sel.selection.isEmpty, "Claude holds the one character under the cursor"
end)

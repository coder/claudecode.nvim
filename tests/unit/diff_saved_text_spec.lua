require("tests.busted_setup")

local diff = require("claudecode.diff")

-- A mock buffer with `empty = true` stands for the buffer that Neovim shows as "--No lines in buffer--", where
-- nvim_buf_get_lines still returns one empty string. tests/integration/diff_accept_emptied_buffer_spec.lua runs the
-- real thing.
describe("The text a split-layout diff saves from its proposal buffer", function()
  local tab_name = "saved_text_tab"
  local buffer = 9001
  local answer

  local function save(lines, eol, empty)
    vim._buffers[buffer] = { lines = lines, options = { eol = eol }, empty = empty }
    answer = nil
    diff._register_diff_state(tab_name, {
      new_buffer = buffer,
      autocmd_ids = {},
      status = "pending",
      resolution_callback = function(result)
        answer = result
      end,
      layout = "vertical",
    })
    diff._resolve_diff_as_saved(tab_name, buffer)
    assert.is_not_nil(answer, "the save answers")
    assert.equals("FILE_SAVED", answer.content[1].text)
    return answer.content[2].text
  end

  after_each(function()
    diff._cleanup_all_active_diffs("test teardown")
    vim._buffers[buffer] = nil
  end)

  it("ends with a line break when the buffer has 'eol' on", function()
    assert.equals("a\nb\n", save({ "a", "b" }, true))
  end)

  it("ends without a line break when the buffer has 'eol' off", function()
    assert.equals("a\nb", save({ "a", "b" }, false))
  end)

  it("keeps a buffer that holds one empty line as that line and its line break", function()
    assert.equals("\n", save({ "" }, true))
  end)

  it("saves an empty buffer as no text, as :w writes no bytes for it, whatever 'eol' says", function()
    assert.equals("", save({ "" }, true, true))
    assert.equals("", save({ "" }, false, true))
  end)
end)

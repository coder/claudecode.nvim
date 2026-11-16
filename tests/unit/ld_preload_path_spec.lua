-- tests/integration/terminal_close_young_job_spec.lua names its LD_PRELOAD shim by a path, and ld.so splits LD_PRELOAD at
-- spaces and colons. The spec keeps the shim out of a folder whose path holds either one. Only CI's TMPDIR holds a space,
-- so this spec is what turns red when the colon half is dropped.
describe("tests.helpers.ld_preload_path", function()
  local ld_preload_path = require("tests.helpers.ld_preload_path")

  it("accepts a path with neither a space nor a colon", function()
    assert.is_true(ld_preload_path.can_name_a_shim("/tmp/nvim.runner/abc123/0"))
    assert.is_true(ld_preload_path.can_name_a_shim("/tmp/tmp50%/nvim"))
  end)

  it("refuses a path with a space", function()
    assert.is_false(ld_preload_path.can_name_a_shim("/home/runner/work/_temp/odd tmp 50%/nvim.runner/abc123/0"))
  end)

  it("refuses a path with a colon", function()
    assert.is_false(ld_preload_path.can_name_a_shim("/tmp/col:tmp/nvim.runner/abc123/0"))
  end)
end)

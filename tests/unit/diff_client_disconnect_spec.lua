--- Tests for issue #248: closing diffs that are orphaned when their owning
--- client disconnects (or via the manual "close all diffs" path).
require("tests.busted_setup")
local diff = require("claudecode.diff")

describe("issue #248: closing orphaned diffs", function()
  local file_a = "/tmp/issue248_a.txt"
  local file_b = "/tmp/issue248_b.txt"

  before_each(function()
    for _, path in ipairs({ file_a, file_b }) do
      local f = io.open(path, "w")
      f:write("line 1\nline 2\n")
      f:close()
    end
  end)

  after_each(function()
    os.remove(file_a)
    os.remove(file_b)
    diff._cleanup_all_active_diffs("test_cleanup")
  end)

  -- Open a pending diff for a given file/tab/client and return a handle whose
  -- `.result` is populated once the diff's coroutine resolves.
  local function open_pending(file, tab_name, client_id)
    local handle = { result = nil }
    handle.co = coroutine.create(function()
      handle.result = diff.open_diff_blocking(file, file, "line 1\nline 2\nnew line\n", tab_name, client_id)
    end)
    local ok, err = coroutine.resume(handle.co)
    assert.is_true(ok, "diff coroutine should start: " .. tostring(err))
    assert.equal("suspended", coroutine.status(handle.co), "diff should be pending")
    return handle
  end

  it("records the owning client_id on the diff state", function()
    open_pending(file_a, "tab-A", "clientA")
    local active = diff._get_active_diffs()
    assert.is_table(active["tab-A"])
    assert.equal("clientA", active["tab-A"].client_id)
  end)

  it("close_diffs_for_client rejects + removes only that client's diffs", function()
    local a = open_pending(file_a, "tab-A", "clientA")
    local b = open_pending(file_b, "tab-B", "clientB")

    local closed = diff.close_diffs_for_client("clientA", "test disconnect")

    assert.equal(1, closed)
    -- clientA's diff resolved as rejected and removed from the registry
    assert.equal("dead", coroutine.status(a.co))
    assert.is_table(a.result)
    assert.equal("DIFF_REJECTED", a.result.content[1].text)
    assert.is_nil(diff._get_active_diffs()["tab-A"])
    -- clientB's diff is untouched
    assert.equal("suspended", coroutine.status(b.co))
    assert.is_table(diff._get_active_diffs()["tab-B"])
  end)

  it("close_diffs_for_client with an unknown client closes nothing", function()
    open_pending(file_a, "tab-A", "clientA")
    assert.equal(0, diff.close_diffs_for_client("nobody", "test"))
    assert.is_table(diff._get_active_diffs()["tab-A"])
  end)

  it("close_diffs_for_client(nil) is a no-op", function()
    open_pending(file_a, "tab-A", "clientA")
    assert.equal(0, diff.close_diffs_for_client(nil, "test"))
    assert.is_table(diff._get_active_diffs()["tab-A"])
  end)

  it("close_all_diffs rejects every diff and drains active_diffs", function()
    local a = open_pending(file_a, "tab-A", "clientA")
    local b = open_pending(file_b, "tab-B", "clientB")

    local closed = diff.close_all_diffs("test all")

    assert.equal(2, closed)
    assert.equal("dead", coroutine.status(a.co))
    assert.equal("dead", coroutine.status(b.co))
    assert.equal("DIFF_REJECTED", a.result.content[1].text)
    assert.equal("DIFF_REJECTED", b.result.content[1].text)
    -- registry fully drained (this is the secondary closeAllDiffTabs bug)
    assert.is_nil(next(diff._get_active_diffs()))
  end)
end)

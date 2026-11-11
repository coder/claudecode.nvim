require("tests.busted_setup")

local temp_dir = require("tests.helpers.temp_dir")

describe("scripts/coverage-summary.sh", function()
  local dir
  local heading = "## 📊 Test Coverage Report\n\n"

  before_each(function()
    dir = temp_dir.new()
  end)

  after_each(function()
    temp_dir.remove(dir)
  end)

  ---@param rows string[]
  ---@return string path
  local function write_report_with_decoy(rows)
    local path = dir .. "/luacov.report.out"
    local file = assert(io.open(path, "w"))
    file:write("==============================================================================\n")
    file:write("lua/claudecode/decoy.lua\n")
    file:write("==============================================================================\n")
    file:write("lua/claudecode/decoy.lua    1    1    50.00%\n")
    file:write("\nSummary\n==============================================================================\n\n")
    file:write("File                                  Hits Missed Coverage\n")
    file:write("-------------------------------------------------------------------\n")
    file:write(table.concat(rows, "\n"), "\n")
    file:close()
    return path
  end

  ---@param ... string
  ---@return string stdout, string stderr, integer exit_code
  local function run(...)
    local stderr_path = dir .. "/stderr.txt"
    local words = {}
    for _, word in ipairs({ ... }) do
      table.insert(words, temp_dir.quote(word))
    end
    local command = "scripts/coverage-summary.sh " .. table.concat(words, " ") .. " 2>" .. temp_dir.quote(stderr_path)
    local pipe = assert(io.popen(command .. '; echo "exit=$?"'))
    local output = pipe:read("*a")
    pipe:close()
    local stdout, code = output:match("^(.*)exit=(%d+)%s*$")
    assert(stdout, "no exit code in: " .. output)
    local stderr_file = assert(io.open(stderr_path, "r"))
    local stderr = stderr_file:read("*a")
    stderr_file:close()
    return stdout, stderr, tonumber(code)
  end

  local function valid_rows()
    return {
      dir .. "/lua/claudecode/a.lua    10    0    100.00%",
      "lua/claudecode/b.lua    9    1    90.00%",
      "lua/claudecode/c.lua    8    2    89.99%",
      "lua/claudecode/d.lua    7    3    70.00%",
      "lua/claudecode/e.lua    6    4    69.99%",
      "lua/claudecode/with space.lua    1    1    50.00%",
      "-------------------------------------------------------------------",
      "Total    41    11    83.33%",
    }
  end

  local valid_summary = heading
    .. "**Overall Coverage: 83.33%**\n\n"
    .. "| File | Coverage |\n"
    .. "|------|----------|\n"
    .. "| `lua/claudecode/a.lua` | 🟢 100.00% |\n"
    .. "| `lua/claudecode/b.lua` | 🟢 90.00% |\n"
    .. "| `lua/claudecode/c.lua` | 🟡 89.99% |\n"
    .. "| `lua/claudecode/d.lua` | 🟡 70.00% |\n"
    .. "| `lua/claudecode/e.lua` | 🔴 69.99% |\n"
    .. "| `lua/claudecode/with space.lua` | 🔴 50.00% |\n"

  it("prints one row per file, with the checkout folder stripped and a mark per threshold", function()
    local stdout, stderr, code = run(write_report_with_decoy(valid_rows()), dir)

    assert.are.equal(valid_summary, stdout)
    assert.are.equal("", stderr)
    assert.are.equal(0, code)
  end)

  it("strips a checkout folder that is given with a trailing slash", function()
    local stdout, _, code = run(write_report_with_decoy(valid_rows()), dir .. "/")

    assert.are.equal(valid_summary, stdout)
    assert.are.equal(0, code)
  end)

  it("fails when the report has no file row", function()
    local stdout, _, code = run(write_report_with_decoy({ "Total    0    0    0.00%" }), dir)

    assert.are.equal(heading .. "❌ luacov.report.out has no per-file row or no Total row\n", stdout)
    assert.are.equal(1, code)
  end)

  it("fails when the report has no Total row", function()
    local stdout, _, code = run(write_report_with_decoy({ "lua/claudecode/a.lua    5    5    50.00%" }), dir)

    assert.are.equal(heading .. "❌ luacov.report.out has no per-file row or no Total row\n", stdout)
    assert.are.equal(1, code)
  end)

  it("fails when a relative path is listed more than once", function()
    local stdout, _, code = run(
      write_report_with_decoy({
        "lua/claudecode/a.lua    5    5    50.00%",
        "lua/claudecode/b.lua    9    1    90.00%",
        "lua/claudecode/a.lua    2    8    20.00%",
        "lua/claudecode/a.lua    1    9    10.00%",
        "Total    17    23    42.50%",
      }),
      dir
    )

    assert.are.equal(
      heading
        .. "❌ luacov.report.out repeats a path (2 extra rows, first `lua/claudecode/a.lua`). Check `modules` in .luacov.\n",
      stdout
    )
    assert.are.equal(1, code)
  end)

  it("fails when one file is listed by its absolute and by its relative path", function()
    local stdout, _, code = run(
      write_report_with_decoy({
        dir .. "/lua/claudecode/a.lua    5    5    50.00%",
        "lua/claudecode/a.lua    2    8    20.00%",
        "Total    7    13    35.00%",
      }),
      dir
    )

    assert.are.equal(
      heading
        .. "❌ luacov.report.out repeats a path (1 extra rows, first `lua/claudecode/a.lua`). Check `modules` in .luacov.\n",
      stdout
    )
    assert.are.equal(1, code)
  end)

  it("exits 2 when the report cannot be read", function()
    local stdout, stderr, code = run(dir .. "/missing.out", dir)

    assert.are.equal("", stdout)
    assert.is_truthy(stderr:find("coverage-summary.sh: cannot read " .. dir .. "/missing.out", 1, true))
    assert.are.equal(2, code)
  end)

  it("exits 64 without the two arguments", function()
    local _, stderr, code = run(write_report_with_decoy(valid_rows()))

    assert.is_truthy(stderr:find("usage: coverage-summary.sh", 1, true))
    assert.are.equal(64, code)
  end)
end)

--- tests/helpers/temp_dir.lua must work under any TMPDIR: one with a space, a quote or a backslash in its path, and a
--- relative one. Each case runs busted in a child process with that TMPDIR.
require("tests.busted_setup")

local temp_dir = require("tests.helpers.temp_dir")
local quote = temp_dir.quote

describe("temp_dir", function()
  local root = require("pl.path").abspath(debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/unit/[^/]+$")
  local outer, parent

  setup(function()
    outer = temp_dir.new()
    parent = outer .. "/dir it's"
    assert(os.execute("mkdir -p " .. quote(parent .. "/back\\slash")))
  end)

  teardown(function()
    temp_dir.remove(outer)
  end)

  -- Each case gives the folder busted starts in, its TMPDIR, and the folder the new folder must be in. The paths are
  -- known only once setup has run.
  for _, case in ipairs({
    {
      "a space and a quote",
      function()
        return root, parent, parent
      end,
    },
    {
      "a backslash",
      function()
        return root, parent .. "/back\\slash", parent .. "/back\\slash"
      end,
    },
    {
      "a relative path",
      function()
        return parent, ".", parent
      end,
    },
  }) do
    it("makes and removes a folder under a TMPDIR with " .. case[1], function()
      local cwd, tmpdir, want = case[2]()
      local spec = parent .. "/fixture_spec.lua"
      local file = assert(io.open(spec, "w"))
      file:write(table.concat({
        "local temp_dir = dofile(" .. string.format("%q", root .. "/tests/helpers/temp_dir.lua") .. ")",
        "local want = " .. string.format("%q", want),
        'it("works", function()',
        "  local dir = temp_dir.new()",
        '  assert(dir:sub(1, #want + 1) == want .. "/", dir)',
        '  assert(io.open(dir .. "/file.txt", "w")):close()',
        "  temp_dir.remove(dir)",
        '  assert(not os.rename(dir, dir), dir .. " is still there")',
        "end)",
      }, "\n"))
      file:close()

      local pipe = assert(
        io.popen(
          string.format(
            "cd %s && TMPDIR=%s %s %s 2>&1; echo status=$?",
            quote(cwd),
            quote(tmpdir),
            quote(root .. "/.luarocks/bin/busted"),
            quote(spec)
          )
        )
      )
      local output = pipe:read("*a")
      pipe:close()

      assert.is_truthy(output:find("status=0", 1, true), output)
    end)
  end

  it("opens a path with a backslash and a space through the mock's :edit", function()
    local path = parent .. "/back\\slash/a file.txt"

    vim.cmd("edit " .. vim.fn.fnameescape(path))

    assert.are_not.equal(-1, vim.fn.bufnr(path), "no buffer has the name " .. path)
  end)
end)

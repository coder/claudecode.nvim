require("tests.busted_setup")

-- actionlint and zizmor check the syntax of .github/workflows/test.yml, not what its cache settings mean, so an edit
-- that loosens one of them keeps CI green. This spec reads the file as text, with no YAML parser, and checks each
-- setting where it sits in its step.
describe(".github/workflows/test.yml cache settings", function()
  local root = require("pl.path").abspath(debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/unit/[^/]+$")
  local steps

  ---Every step is a `- ` item at six spaces. A step ends at the next step or at a line with less indent, and a comment
  ---line is not part of it.
  ---@return string[][] steps the lines of each step
  local function read_steps()
    local path = root .. "/.github/workflows/test.yml"
    local file = assert(
      io.open(path, "r"),
      "cannot read " .. path .. " (a `git archive` tree has no .github folder: .gitattributes export-ignores it)"
    )
    local found = {}
    local current
    for line in file:lines() do
      if line:match("^      %- ") then
        current = {}
        table.insert(found, current)
      elseif line:match("%S") and #line:match("^ *") < 6 then
        current = nil
      end
      if current and not line:match("^%s*#") then
        table.insert(current, line)
      end
    end
    file:close()
    assert(#found > 0, "no steps found in " .. path)
    return found
  end

  ---Finds a setting by its place in the step: a key of the step itself sits at eight spaces (the `- name:` line
  ---counts), and an entry of its `with:` or `env:` block sits at ten.
  ---@param step string[]
  ---@param key string
  ---@param block string|nil `"with"` or `"env"`, the step key whose block holds `key`. nil for a key of the step
  ---@return string|nil value the text after `key:`, without a trailing YAML comment
  local function field(step, key, block)
    local current
    for _, text in ipairs(step) do
      local line = text:gsub("^      %- ", "        ", 1)
      local indent = #line:match("^ *")
      local name, value = line:match("^ *([%w_%-]+):%s*(.-)%s*$")
      if name and indent == 8 then
        current = name
      end
      local in_place = (indent == 8 and block == nil) or (indent == 10 and block ~= nil and current == block)
      if name == key and in_place then
        return (value:gsub("%s+#.*$", ""))
      end
    end
    return nil
  end

  ---@param step string[]
  ---@return boolean caches_rocks whether an actions/cache step names the rock tree in any way: `.luarocks`,
  ---`./.luarocks`, an absolute path, a line of a multi-line `path`
  local function caches_rock_tree(step)
    if not (field(step, "uses") or ""):match("^actions/cache[/@]") then
      return false
    end
    for _, line in ipairs(step) do
      if line:find(".luarocks", 1, true) then
        return true
      end
    end
    return false
  end

  ---@param name string
  ---@return string[] step
  local function find_step(name)
    local found
    for _, step in ipairs(steps) do
      if field(step, "name") == name then
        assert(found == nil, "two steps are named " .. name)
        found = step
      end
    end
    return assert(found, "no step is named " .. name)
  end

  before_each(function()
    steps = read_steps()
  end)

  describe("the Set up mise step", function()
    local step

    before_each(function()
      step = find_step("Set up mise")
    end)

    it("keys the tool cache on mise.lock only", function()
      local key = field(step, "cache_key", "with")
      assert.is_string(key, "the step has no cache_key under with:")
      assert.is_truthy(key:find("${{ hashFiles('mise.lock') }}", 1, true), "cache_key must hash mise.lock: " .. key)
      assert.are.equal(1, select(2, key:gsub("hashFiles%(", "")), "cache_key must hash nothing else: " .. key)
      assert.is_nil(key:find("file_hash", 1, true), "{{file_hash}} hashes every mise config file: " .. key)
      assert.is_nil(key:find("{{default}}", 1, true), "{{default}} hashes every mise config file: " .. key)
    end)

    it("restores from the exact key only", function()
      for _, line in ipairs(step) do
        assert.is_nil(line:find("restore-keys", 1, true), "a restore-keys fallback is not allowed: " .. line)
      end
    end)

    it("saves the cache only on a push", function()
      assert.are.equal("${{ github.event_name == 'push' }}", field(step, "cache_save", "with"))
    end)

    it("retries a failed download at least 6 times", function()
      local retries = field(step, "MISE_HTTP_RETRIES", "env")
      assert.is_string(retries, "the step sets no MISE_HTTP_RETRIES under env:")
      local digits = retries:match("^[\"']?(%d+)[\"']?$")
      assert.is_truthy(digits, "MISE_HTTP_RETRIES must be an integer: " .. retries)
      assert.is_true(tonumber(digits) >= 6, "MISE_HTTP_RETRIES is below 6: " .. retries)
    end)
  end)

  describe("the rock cache", function()
    local restore, save

    before_each(function()
      local rock_steps = {}
      for _, step in ipairs(steps) do
        if caches_rock_tree(step) then
          table.insert(rock_steps, step)
        end
      end
      local uses = {}
      for _, step in ipairs(rock_steps) do
        table.insert(uses, (string.gsub(field(step, "uses") or "none", "@.*$", "")))
      end
      assert.are.same(
        { "actions/cache/restore", "actions/cache/save" },
        uses,
        "the steps that cache .luarocks must be a restore and then a save: actions/cache saves in a post step"
      )
      restore, save = rock_steps[1], rock_steps[2]
    end)

    it("restores and saves with the same pinned action", function()
      local restore_sha = field(restore, "uses"):match("@(%x+)$")
      local save_sha = field(save, "uses"):match("@(%x+)$")
      assert.is_true(restore_sha ~= nil and #restore_sha == 40, "pin the restore step to a commit SHA")
      assert.are.equal(restore_sha, save_sha)
    end)

    it("restores and saves the same path", function()
      -- The cache version comes from the path, so a save under another spelling of it is never restored.
      assert.are.equal(".luarocks", field(restore, "path", "with"))
      assert.are.equal(".luarocks", field(save, "path", "with"))
    end)

    it("restores the key that the rock list in mise.toml decides", function()
      local key = field(restore, "key", "with")
      assert.is_string(key, "the restore step has no key under with:")
      assert.is_truthy(key:find("hashFiles('mise.toml')", 1, true), key)
    end)

    it("restores from the exact key only", function()
      -- `mise run setup` skips the install when busted, luacheck and luacov exist, so a tree restored from another
      -- mise.toml would keep rocks whose pins changed.
      for _, line in ipairs(restore) do
        assert.is_nil(line:find("restore-keys", 1, true), "a restore-keys fallback is not allowed: " .. line)
      end
    end)

    it("saves under the key that the restore step tried", function()
      local id = field(restore, "id")
      assert.is_string(id, "the restore step needs an id")
      assert.are.equal("${{ steps." .. id .. ".outputs.cache-primary-key }}", field(save, "key", "with"))
    end)

    it("saves only on a push, and only after a miss", function()
      local id = field(restore, "id")
      assert.is_string(id, "the restore step needs an id")
      assert.are.equal(
        "github.event_name == 'push' && steps." .. id .. ".outputs.cache-hit != 'true'",
        field(save, "if")
      )
    end)
  end)
end)

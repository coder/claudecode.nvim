require("tests.busted_setup")

-- actionlint and zizmor check the syntax of .github/workflows/test.yml, not what its cache settings mean, so an edit
-- that loosens one of them keeps CI green. This spec reads the file as text, with no YAML parser, and checks each
-- setting where it sits in its step. It also fails when `actions/cache` or `jdx/mise-action` is named on a line that is
-- not the `uses:` of a block-style step. It skips full-line comments, so a comment can name an action (the one above
-- the rock cache steps does). It does not decode YAML escapes.
describe(".github/workflows/test.yml cache settings", function()
  local root = require("pl.path").abspath(debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/unit/[^/]+$")
  local push_only = "${{ github.event_name == 'push' }}"
  local steps, lines

  ---Every step is a `- ` item at six spaces. A step ends at the next step or at a line with less indent, and a comment
  ---line is not part of it.
  ---@param next_line fun(): string|nil an iterator over the lines of a workflow
  ---@return string[][] steps the lines of each step
  ---@return string[] lines every line of the text that is not a comment line. A trailing comment stays: a ` #` can sit
  ---inside a quoted value, so cutting there could hide a name in a flow-style step.
  local function parse_workflow(next_line)
    local found = {}
    local code = {}
    local current
    for line in next_line do
      if not line:match("^%s*#") then
        table.insert(code, line)
      end
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
    return found, code
  end

  ---@return string[][] steps
  ---@return string[] lines
  local function read_workflow()
    local path = root .. "/.github/workflows/test.yml"
    local file = assert(
      io.open(path, "r"),
      "cannot read " .. path .. " (a `git archive` tree has no .github folder: .gitattributes export-ignores it)"
    )
    local found, code = parse_workflow(file:lines())
    file:close()
    assert(#found > 0, "no steps found in " .. path)
    return found, code
  end

  ---@param value string
  ---@return string unquoted the value without one pair of YAML quotes around it
  local function unquote(value)
    local inner = value:match('^"(.*)"$')
    if inner then
      return inner
    end
    inner = value:match("^'(.*)'$")
    if inner then
      return (inner:gsub("''", "'"))
    end
    return value
  end

  ---Finds a setting by its place in the step: a key of the step itself sits at eight spaces (the `- name:` line
  ---counts), and an entry of its `with:` or `env:` block sits at ten.
  ---@param step string[]
  ---@param key string the key, which the file may write bare or in a matching pair of quotes
  ---@param block string|nil `"with"` or `"env"`, the step key whose block holds `key`. nil for a key of the step
  ---@return string|nil value the text after `key:`, without a trailing YAML comment and without quotes around it
  local function field(step, key, block)
    local current
    for _, text in ipairs(step) do
      local line = text:gsub("^      %- ", "        ", 1)
      local indent = #line:match("^ *")
      local name, value
      for _, pattern in ipairs({
        '^ *"([%w_%-]+)":%s*(.-)%s*$',
        "^ *'([%w_%-]+)':%s*(.-)%s*$",
        "^ *([%w_%-]+):%s*(.-)%s*$",
      }) do
        name, value = line:match(pattern)
        if name then
          break
        end
      end
      -- Any non-blank line at the step-key indent opens a new block, even when no pattern reads its key (`env :`). A
      -- line of spaces only does not.
      if indent == 8 and line:match("%S") then
        current = name
      end
      local in_place = (indent == 8 and block == nil) or (indent == 10 and block ~= nil and current == block)
      if name == key and in_place then
        return unquote((value:gsub("%s+#.*$", "")))
      end
    end
    return nil
  end

  ---@param step string[]
  ---@param action string an action name without a version, such as `actions/cache`
  ---@return boolean uses_it whether the step's `uses:` starts with the name and `@` or `/` follows it
  local function uses_action(step, action)
    local uses = field(step, "uses") or ""
    local after = uses:sub(#action + 1, #action + 1)
    return uses:sub(1, #action) == action and (after == "@" or after == "/")
  end

  ---@param step string[]
  ---@return boolean caches_rocks whether the step uses actions/cache (plain, restore or save) and one of its lines
  ---contains the text `.luarocks`: as `.luarocks`, `./.luarocks`, `~/.luarocks`, an absolute path, or a line of a
  ---multi-line `path`. A path without that text (a glob such as `.luaroc*`, or a parent folder) is not seen.
  local function caches_rock_tree(step)
    if not uses_action(step, "actions/cache") then
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
    steps, lines = read_workflow()
  end)

  describe("the reader", function()
    ---@param text string
    ---@return fun(): string|nil next_line
    local function split_lines(text)
      local rows = {}
      for row in (text .. "\n"):gmatch("(.-)\n") do
        table.insert(rows, row)
      end
      local index = 0
      return function()
        index = index + 1
        return rows[index]
      end
    end

    ---@param ... string the lines of the keys that follow `with:` in a `jdx/mise-action` step
    ---@return string[] step
    local function mise_step(...)
      local text = table.concat({
        "      - name: Set up more mise tools",
        "        uses: jdx/mise-action@1648a7812b9aeae629881980618f079932869151",
        "        with:",
        "          install_args: --locked",
        table.concat({ ... }, "\n"),
      }, "\n")
      return (parse_workflow(split_lines(text)))[1]
    end

    it("ends the with: block at a step key that no key pattern reads", function()
      for _, env in ipairs({ "env :", '"env" :' }) do
        local step = mise_step("        " .. env, "          cache: false")
        assert.are.equal("--locked", field(step, "install_args", "with"))
        assert.is_nil(field(step, "cache", "with"), "cache: false sits under " .. env .. ", not under with:")
      end
    end)

    it("keeps the with: block open over a line of spaces", function()
      local step = mise_step("        ", "          cache: false")
      assert.are.equal("false", field(step, "cache", "with"))
    end)

    it("does not read a key with a quote on one side only", function()
      local step = mise_step(
        "          cache_save\": ${{ github.event_name == 'push' }}",
        "          cache': false",
        '          "cache_key: a',
        "          cache_key': b"
      )
      assert.is_nil(field(step, "cache_save", "with"))
      assert.is_nil(field(step, "cache", "with"))
      assert.is_nil(field(step, "cache_key", "with"))
    end)

    it("reads a bare key and a key in a matching pair of quotes", function()
      local step = mise_step("          cache_key: bare", '          "cache_save": double', "          'cache': single")
      assert.are.equal("bare", field(step, "cache_key", "with"))
      assert.are.equal("double", field(step, "cache_save", "with"))
      assert.are.equal("single", field(step, "cache", "with"))
      assert.are.equal("jdx/mise-action@1648a7812b9aeae629881980618f079932869151", field(step, "uses"))
    end)
  end)

  describe("the workflow text", function()
    -- field() reads block style only. This test counts the lines that contain an action name, in any letter case, and
    -- the steps whose `uses:` is the name in lower case followed by `@` or `/`. The two counts must be equal. So it
    -- fails for a flow-style step (`- { uses: actions/cache@..., with: { ... } }`), for another letter case
    -- (`Actions/cache@`), and for the name on any other line that is not a comment line (a step `name:`, a `run:`
    -- line, a trailing comment). It does not decode YAML escapes, so `"actions\x2fcache@..."` is not seen.
    it("names actions/cache and jdx/mise-action only in steps it can read", function()
      for _, action in ipairs({ "actions/cache", "jdx/mise-action" }) do
        local named, read = 0, 0
        for _, line in ipairs(lines) do
          if line:lower():find(action, 1, true) then
            named = named + 1
          end
        end
        for _, step in ipairs(steps) do
          if uses_action(step, action) then
            read = read + 1
          end
        end
        assert.are.equal(
          named,
          read,
          action .. " is named on " .. named .. " lines, but only " .. read .. " steps have it as their uses:"
        )
      end
    end)

    it("keeps the cache of every jdx/mise-action step off a pull request", function()
      -- The default of cache_save is true, so a step that sets neither would save the tool cache on a pull request.
      local checked = 0
      for _, step in ipairs(steps) do
        if uses_action(step, "jdx/mise-action") then
          checked = checked + 1
          local cache_save = field(step, "cache_save", "with")
          local safe = field(step, "cache", "with") == "false" or cache_save == "false" or cache_save == push_only
          assert.is_true(
            safe,
            "this jdx/mise-action step saves its cache on a pull request: " .. tostring(field(step, "name"))
          )
        end
      end
      assert.is_true(checked >= 1, "no jdx/mise-action step found")
    end)
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
      assert.is_truthy(
        key:match("^mise%-v%d+%-{{platform}}%-{{version}}%-%${{ hashFiles%('mise%.lock'%) }}$"),
        "cache_key must be mise-v<n>-{{platform}}-{{version}}-${{ hashFiles('mise.lock') }}: " .. key
      )
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
      assert.are.equal(push_only, field(step, "cache_save", "with"))
    end)

    it("retries a failed download at least 6 times", function()
      local retries = field(step, "MISE_HTTP_RETRIES", "env")
      assert.is_string(retries, "the step sets no MISE_HTTP_RETRIES under env:")
      assert.is_truthy(retries:match("^%d+$"), "MISE_HTTP_RETRIES must be an integer: " .. retries)
      assert.is_true(tonumber(retries) >= 6, "MISE_HTTP_RETRIES is below 6: " .. retries)
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
      -- A version after the prefix (`luarocks-v2-`) is allowed, as `v1` is in the mise key: bump it to drop a tree.
      local bare = key:gsub("^luarocks%-v%d+%-", "luarocks-")
      assert.is_truthy(
        bare:match("^luarocks%-%${{ runner%.os }}%-%${{ hashFiles%('mise%.toml'%) }}$"),
        "the restore key must be luarocks-${{ runner.os }}-${{ hashFiles('mise.toml') }}: " .. key
      )
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

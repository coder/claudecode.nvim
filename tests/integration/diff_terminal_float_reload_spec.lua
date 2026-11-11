if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("a floating Claude terminal after the plugin reloaded", function()
    pending("needs a real Neovim")
  end)
  return
end

-- :Lazy reload clears every claudecode module and runs setup again. Snacks keeps its terminal instances, so the new
-- copy of the snacks provider adopts the instance that the old copy started, and the old copy's patched show, hide and
-- toggle stay on it. These cases run the real provider and the real diff module against a stub of Snacks with real
-- windows and a real terminal job (`sleep`, never the claude CLI). A float that a diff hid, or that the user hid or
-- closed, must stay that way when the diff closes.
describe("a floating Claude terminal after the plugin reloaded", function()
  local dir
  local stub

  local function install_stub_snacks()
    local instances = {}
    local snacks = { terminal = {}, util = { wo = function() end } }
    function snacks.terminal.list()
      return instances
    end
    function snacks.terminal.open(_, opts)
      local buf = vim.api.nvim_create_buf(false, true)
      local term = { buf = buf, opts = { wo = {}, w = {}, position = "float" } }
      local function open_window()
        term.win = vim.api.nvim_open_win(buf, false, {
          relative = "editor",
          row = 1,
          col = 1,
          width = vim.o.columns - 4,
          height = vim.o.lines - 6,
        })
      end
      function term:buf_valid()
        return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
      end
      function term:win_valid()
        return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
      end
      function term:on() end
      function term:focus()
        if self:win_valid() then
          vim.api.nvim_set_current_win(self.win)
        end
      end
      function term:close()
        if self:win_valid() then
          pcall(vim.api.nvim_win_close, self.win, true)
        end
        self.win = nil
        if self:buf_valid() then
          pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
        end
      end
      -- Snacks' own methods. Closing the window is what Snacks does on hide, and show opens it again.
      function term:hide()
        if self:win_valid() then
          pcall(vim.api.nvim_win_close, self.win, true)
        end
        self.win = nil
        return self
      end
      function term:show()
        if not self:win_valid() then
          open_window()
        end
        return self
      end
      function term:toggle()
        if self:win_valid() then
          return self:hide()
        end
        return self:show()
      end
      open_window()
      if opts.win and opts.win.on_buf then
        opts.win.on_buf(term)
      end
      vim.api.nvim_buf_call(buf, function()
        vim.fn.termopen({ "sleep", "300" })
      end)
      instances[#instances + 1] = term
      return term
    end
    package.loaded["snacks"] = snacks
    return snacks
  end

  local function load_plugin()
    for name in pairs(package.loaded) do
      if name:match("^claudecode") then
        package.loaded[name] = nil
      end
    end
    local plugin = {
      terminal = require("claudecode.terminal"),
      provider = require("claudecode.terminal.snacks"),
      diff = require("claudecode.diff"),
      tools = require("claudecode.tools.init"),
    }
    plugin.terminal.setup({ provider = plugin.provider }, nil, nil)
    local cfg = vim.deepcopy(require("claudecode.config").defaults)
    cfg.terminal = vim.tbl_extend("force", cfg.terminal or {}, { auto_insert = false })
    cfg.diff_opts = vim.tbl_extend("force", cfg.diff_opts or {}, { layout = "vertical" })
    plugin.diff.setup(cfg)
    plugin.tools.register_all()
    return plugin
  end

  local function open_float(plugin)
    plugin.provider.open("sleep 300", {}, {
      cwd = dir,
      split_side = "right",
      split_width_percentage = 0.3,
      auto_close = false,
      auto_insert = false,
      snacks_win_opts = { position = "float" },
    }, false)
    local instances = stub.terminal.list()
    local term = instances[#instances]
    assert.is_true(term:win_valid(), "the float is open")
    return term
  end

  local function visible_floats(term)
    local count = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
      local cfg = vim.api.nvim_win_get_config(win)
      if (cfg.relative or "") ~= "" and vim.api.nvim_win_get_buf(win) == term.buf and cfg.hide ~= true then
        count = count + 1
      end
    end
    return count
  end

  local function tab_name_of(file)
    return "✻ [Claude Code] " .. file .. " ⧉"
  end

  local function open_diff(plugin, file)
    local path = dir .. "/" .. file
    local call = plugin.tools.handle_invoke({ id = "reload_spec_" .. file }, {
      name = "openDiff",
      arguments = {
        old_file_path = path,
        new_file_path = path,
        new_file_contents = "alpha accepted\n",
        tab_name = tab_name_of(file),
      },
    })
    assert.is_true(call._deferred, vim.inspect(call.error))
    _G.claude_deferred_responses[tostring(call.coroutine)] = function() end
  end

  local function close_tab(plugin, file)
    plugin.tools.handle_invoke(
      { id = "reload_spec_close_" .. file },
      { name = "close_tab", arguments = { tab_name = tab_name_of(file) } }
    )
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "alpha" }, dir .. "/proposed.txt")
    stub = install_stub_snacks()
    _G.claude_deferred_responses = {}
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/proposed.txt"))
  end)

  after_each(function()
    pcall(function()
      require("claudecode.diff")._cleanup_all_active_diffs("test cleanup")
    end)
    for _, term in ipairs(stub.terminal.list()) do
      if term:buf_valid() then
        pcall(vim.fn.jobstop, vim.bo[term.buf].channel)
      end
    end
    vim.cmd("silent! stopinsert")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    package.loaded["snacks"] = nil
    for name in pairs(package.loaded) do
      if name:match("^claudecode") then
        package.loaded[name] = nil
      end
    end
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  for _, reloads in ipairs({ 0, 1, 2 }) do
    local after = reloads == 0 and "without a reload" or ("after " .. reloads .. " reload(s)")

    it("hides the float for the diff and leaves it hidden when the diff closes, " .. after, function()
      local plugin = load_plugin()
      local term = open_float(plugin)
      for _ = 1, reloads do
        plugin = load_plugin()
      end

      open_diff(plugin, "proposed.txt")
      assert.equal(0, visible_floats(term), "the diff hid the float")
      close_tab(plugin, "proposed.txt")

      assert.equal(0, visible_floats(term), "nothing shows the float again")
      assert.is_not.equal(term.win, vim.api.nvim_get_current_win(), "the cursor is not in the float")
    end)

    it("keeps a float hidden that the user showed and hid through the Snacks instance, " .. after, function()
      local plugin = load_plugin()
      local term = open_float(plugin)
      for _ = 1, reloads do
        plugin = load_plugin()
      end

      open_diff(plugin, "proposed.txt")
      assert.equal(0, visible_floats(term), "the diff hid the float")
      term:toggle()
      assert.equal(1, visible_floats(term), "the user showed the float")
      term:hide()
      assert.equal(0, visible_floats(term), "the user hid the float, as Snacks' q does")

      close_tab(plugin, "proposed.txt")

      assert.equal(0, visible_floats(term), "the float stays hidden")
      assert.is_not.equal(term.win, vim.api.nvim_get_current_win(), "the cursor is not in the float")
    end)

    it("keeps a float closed that the user showed and closed with :close, " .. after, function()
      local plugin = load_plugin()
      local term = open_float(plugin)
      for _ = 1, reloads do
        plugin = load_plugin()
      end

      open_diff(plugin, "proposed.txt")
      term:toggle()
      assert.equal(1, visible_floats(term), "the user showed the float")
      vim.api.nvim_win_close(term.win, true)

      close_tab(plugin, "proposed.txt")

      assert.equal(0, visible_floats(term), "the float that the user closed stays closed")
    end)
  end
end)

-- luacheck: globals expect
require("tests.busted_setup")

describe("snacks picker integration", function()
  local integrations
  local mock_vim

  -- Builds a fake snacks picker object that mimics the public surface the
  -- handler relies on: `picker.list.win.win` (the list window id, used for
  -- focus matching) and `picker:selected({ fallback = true })`.
  local function make_picker(win_id, items)
    return {
      list = { win = { win = win_id } },
      selected = function(_, opts)
        expect(opts).to_be_table()
        expect(opts.fallback).to_be_true()
        return items
      end,
    }
  end

  -- Installs the snacks mock. `pickers` is the list returned by
  -- Snacks.picker.get({ tab = true }).
  local function set_snacks(pickers)
    package.loaded["snacks"] = {
      picker = {
        get = function(opts)
          expect(opts).to_be_table()
          expect(opts.tab).to_be_true()
          return pickers
        end,
        util = {
          -- Mirrors the real Snacks.picker.util.path: nil when no string file,
          -- absolute item.file returned as-is, else joined to cwd.
          path = function(item)
            if not (item and type(item.file) == "string") then
              return nil
            end
            if item.file:sub(1, 1) == "/" then
              return item.file
            end
            return (type(item.cwd) == "string") and (item.cwd .. "/" .. item.file) or item.file
          end,
        },
      },
    }
  end

  local function setup_mocks()
    package.loaded["claudecode.integrations"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["snacks"] = nil

    -- Mock logger
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
    }

    mock_vim = {
      fn = {
        filereadable = function(path)
          if path:match("/nonexistent/") or path:match("missing") then
            return 0
          elseif path:match("%.lua$") or path:match("%.txt$") or path:match("%.md$") then
            return 1
          end
          return 0
        end,
        isdirectory = function(path)
          if path:match("/nonexistent/") then
            return 0
          elseif path:match("/$") or path:match("/src$") or path:match("/docs$") then
            return 1
          end
          return 0
        end,
      },
      bo = { filetype = "snacks_picker_list" },
      api = {
        nvim_get_current_win = function()
          return 1000
        end,
      },
    }

    _G.vim = mock_vim
  end

  before_each(function()
    setup_mocks()
    integrations = require("claudecode.integrations")
  end)

  describe("_get_snacks_picker_selection", function()
    it("should return error when snacks is not available", function()
      package.loaded["snacks"] = nil

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_match("not available")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should return error when snacks has no picker module", function()
      package.loaded["snacks"] = {}

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_match("not available")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should return error when no active picker is found", function()
      set_snacks({})

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be("No active snacks picker found")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should return a single file from the cursor fallback", function()
      local picker = make_picker(1000, {
        { file = "single.lua", cwd = "/test/project" },
      })
      set_snacks({ picker })

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/single.lua")
    end)

    it("should return multiple files from a multi-selection in order", function()
      local picker = make_picker(1000, {
        { file = "first.lua", cwd = "/test/project" },
        { file = "second.txt", cwd = "/test/project" },
      })
      set_snacks({ picker })

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(2)
      expect(files[1]).to_be("/test/project/first.lua")
      expect(files[2]).to_be("/test/project/second.txt")
    end)

    it("should skip file-less items (registers/commands)", function()
      local picker = make_picker(1000, {
        { file = "real.lua", cwd = "/test/project" },
        { text = ":registers", cwd = "/test/project" }, -- no .file
        { file = "also.md", cwd = "/test/project" },
      })
      set_snacks({ picker })

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(2)
      expect(files[1]).to_be("/test/project/real.lua")
      expect(files[2]).to_be("/test/project/also.md")
    end)

    it("should fall back to manual cwd/file join when util.path raises", function()
      local picker = make_picker(1000, {
        { file = "fallback.lua", cwd = "/test/project" },
      })
      set_snacks({ picker })
      -- Simulate the undocumented resolver blowing up.
      package.loaded["snacks"].picker.util.path = function()
        error("snacks.picker.util.path exploded")
      end

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/fallback.lua")
    end)

    it("should fall back to manual cwd/file join when util.path returns nil", function()
      local picker = make_picker(1000, {
        { file = "nilpath.lua", cwd = "/test/project" },
      })
      set_snacks({ picker })
      -- Resolver returns nil (e.g. an item shape it does not recognize).
      package.loaded["snacks"].picker.util.path = function()
        return nil
      end

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/nilpath.lua")
    end)

    it("should use an absolute item.file (no cwd) directly in the manual fallback", function()
      -- Explorer-style item: absolute file, no cwd. When util.path fails, the
      -- manual fallback must return item.file unchanged (no doubled prefix).
      local picker = make_picker(1000, {
        { file = "/test/project/abs.lua" },
      })
      set_snacks({ picker })
      package.loaded["snacks"].picker.util.path = function()
        return nil
      end

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/abs.lua")
    end)

    it("should return error when picker:selected raises", function()
      local picker = {
        list = { win = { win = 1000 } },
        selected = function()
          error("selected blew up")
        end,
      }
      set_snacks({ picker })

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be("Failed to read snacks picker selection")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should return error when picker:selected returns a non-table", function()
      local picker = {
        list = { win = { win = 1000 } },
        selected = function()
          return nil
        end,
      }
      set_snacks({ picker })

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be("Failed to read snacks picker selection")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should accept a directory item (Snacks.explorer)", function()
      -- Explorer directory nodes carry a file path that is a directory, not a
      -- readable file; the isdirectory() branch must accept them.
      local picker = make_picker(1000, {
        { file = "src", cwd = "/test/project" },
      })
      set_snacks({ picker })

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/src")
    end)

    it("should skip an item whose file is not a string", function()
      local picker = make_picker(1000, {
        { file = 123, cwd = "/test/project" }, -- malformed/non-string file
        { file = "valid.lua", cwd = "/test/project" },
      })
      set_snacks({ picker })

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/valid.lua")
    end)

    it("should filter out nonexistent paths", function()
      local picker = make_picker(1000, {
        { file = "exists.lua", cwd = "/test/project" },
        { file = "missing.lua", cwd = "/nonexistent" },
      })
      set_snacks({ picker })

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/exists.lua")
    end)

    it("should return error when selection yields no valid files", function()
      local picker = make_picker(1000, {
        { file = "missing.lua", cwd = "/nonexistent" },
      })
      set_snacks({ picker })

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be("No file found in snacks picker selection")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should pick the picker whose list window is focused", function()
      -- Three pickers on the tab; the focused window matches the FIRST one's
      -- list, which is deliberately neither the last element (the
      -- pickers[#pickers] fallback) nor adjacent to it. A working focus-match
      -- loop returns from_a.lua; a dead loop falls through to the fallback and
      -- returns from_c.lua, failing this test.
      local picker_a = make_picker(1000, {
        { file = "from_a.lua", cwd = "/test/project" },
      })
      local picker_b = make_picker(2000, {
        { file = "from_b.lua", cwd = "/test/project" },
      })
      local picker_c = make_picker(3000, {
        { file = "from_c.lua", cwd = "/test/project" },
      })
      set_snacks({ picker_a, picker_b, picker_c })

      mock_vim.api.nvim_get_current_win = function()
        return 1000
      end

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/from_a.lua")
    end)

    it("should fall back to the most-recent picker when no window matches", function()
      local picker_a = make_picker(1000, {
        { file = "from_a.lua", cwd = "/test/project" },
      })
      local picker_b = make_picker(2000, {
        { file = "from_b.lua", cwd = "/test/project" },
      })
      set_snacks({ picker_a, picker_b })

      -- Current window matches neither picker's list window.
      mock_vim.api.nvim_get_current_win = function()
        return 9999
      end

      local files, err = integrations._get_snacks_picker_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      -- Most-recent (last) picker is used as the fallback.
      expect(files[1]).to_be("/test/project/from_b.lua")
    end)
  end)

  describe("get_selected_files_from_tree", function()
    it("should detect snacks_picker_list filetype and delegate to the snacks handler", function()
      mock_vim.bo.filetype = "snacks_picker_list"

      local picker = make_picker(1000, {
        { file = "delegated.lua", cwd = "/test/project" },
      })
      set_snacks({ picker })

      local files, err = integrations.get_selected_files_from_tree()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/delegated.lua")
    end)
  end)
end)

-- Regression tests for issue #289:
--   ClaudeCodeSend must classify tree/explorer buffers by FILETYPE only, not by
--   a substring match on the buffer name (an absolute path). A normal
--   filetype=lua file whose path contains "neo-tree"/"NvimTree" must NOT be
--   treated as a tree buffer.
--
-- Unlike tree_send_visual_spec.lua (which mocks the visual_commands wrapper),
-- these tests drive the REAL create_visual_command_wrapper + the REAL
-- is_tree_buffer predicate, so they actually exercise the classification logic.

require("tests.busted_setup")
require("tests.mocks.vim")

describe("ClaudeCodeSend tree-buffer classification (#289)", function()
  local claudecode
  local command_callback
  local original_require

  local mock_selection
  local mock_integrations

  -- Buffer/editor state the predicate and wrapper read; mutated per test.
  local cur = { ft = "lua", bufname = "/home/user/cfg/lua/plugins/_neo-tree_.lua", mode = "n" }

  before_each(function()
    package.loaded["claudecode"] = nil
    package.loaded["claudecode.selection"] = nil
    package.loaded["claudecode.integrations"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.server.init"] = nil
    package.loaded["claudecode.lockfile"] = nil
    package.loaded["claudecode.config"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.diff"] = nil
    -- visual_commands is intentionally NOT mocked: we use the real wrapper.
    package.loaded["claudecode.visual_commands"] = nil

    cur = { ft = "lua", bufname = "/home/user/cfg/lua/plugins/_neo-tree_.lua", mode = "n" }

    _G.vim = {
      api = {
        nvim_create_user_command = function(name, callback)
          if name == "ClaudeCodeSend" then
            command_callback = callback
          end
        end,
        nvim_create_augroup = function()
          return 1
        end,
        nvim_create_autocmd = function()
          return 1
        end,
        nvim_get_mode = function()
          return { mode = cur.mode }
        end,
        nvim_buf_get_name = function()
          return cur.bufname
        end,
        nvim_feedkeys = function()
          -- Feeding <Esc> drops us out of visual mode, exactly as the real
          -- exit_visual_and_schedule path does before the scheduled handler runs.
          cur.mode = "n"
        end,
        nvim_replace_termcodes = function(s)
          return s
        end,
        nvim_win_get_cursor = function()
          return { 1, 0 }
        end,
      },
      bo = setmetatable({}, {
        __index = function(_, k)
          if k == "filetype" then
            return cur.ft
          end
        end,
      }),
      fn = {
        mode = function()
          return cur.mode
        end,
        getpos = function()
          return { 0, 1, 0, 0 }
        end,
        line = function(mark)
          return mark == "'<" and 1 or 3
        end,
      },
      schedule = function(fn)
        fn()
      end,
      notify = function() end,
      log = { levels = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5 } },
      deepcopy = function(t)
        return t
      end,
      tbl_deep_extend = function(_, ...)
        local result = {}
        for _, tbl in ipairs({ ... }) do
          for k, v in pairs(tbl) do
            result[k] = v
          end
        end
        return result
      end,
    }

    mock_selection = {
      send_at_mention_for_visual_selection = spy.new(function(l1, l2)
        mock_selection.last = { l1, l2 }
        return true
      end),
    }

    mock_integrations = {
      get_selected_files_from_tree = spy.new(function()
        return { "/proj/from_tree.lua" }, nil
      end),
      _get_mini_files_selection_with_range = function()
        return {}, "unused"
      end,
    }

    local mock_logger = {
      setup = function() end,
      debug = function() end,
      warn = function() end,
      error = spy.new(function() end),
    }
    mock_selection._logger = mock_logger

    original_require = _G.require
    _G.require = function(module)
      if module == "claudecode.selection" then
        return mock_selection
      elseif module == "claudecode.integrations" then
        return mock_integrations
      elseif module == "claudecode.logger" then
        return mock_logger
      elseif module == "claudecode.terminal" then
        return { setup = function() end, open = function() end, ensure_visible = function() end }
      elseif module == "claudecode.server.init" then
        return {
          get_status = function()
            return { running = true, client_count = 1 }
          end,
        }
      elseif module == "claudecode.lockfile" then
        return {
          create = function()
            return true, "/tmp/mock.lock", "auth"
          end,
          remove = function()
            return true
          end,
          generate_auth_token = function()
            return "auth"
          end,
        }
      elseif module == "claudecode.config" then
        return {
          apply = function(opts)
            return opts or { log_level = "info" }
          end,
        }
      elseif module == "claudecode.diff" then
        return { setup = function() end }
      else
        return original_require(module)
      end
    end

    claudecode = require("claudecode")
    claudecode.setup({ auto_start = false })
    claudecode.state.server = { broadcast = spy.new(function()
      return true
    end) }
    claudecode.state.port = 12345
    -- Tree path fans out via M.send_at_mention; stub it so we can detect routing.
    claudecode.send_at_mention = spy.new(function()
      return true
    end)
  end)

  after_each(function()
    _G.require = original_require
  end)

  it("registers the ClaudeCodeSend command", function()
    assert.is_function(command_callback)
  end)

  it("does NOT treat a lua file whose path contains 'neo-tree' as a tree buffer (range path)", function()
    cur.ft = "lua"
    cur.mode = "n"
    cur.bufname = "/home/user/cfg/lua/plugins/_neo-tree_.lua"

    command_callback({ range = 2, line1 = 1, line2 = 3 })

    -- Correct routing: the normal selection path, NOT tree extraction.
    assert.spy(mock_selection.send_at_mention_for_visual_selection).was_called()
    assert.same({ 1, 3 }, mock_selection.last)
    assert.spy(mock_integrations.get_selected_files_from_tree).was_not_called()
  end)

  it("does NOT treat a lua file whose path contains 'NvimTree' as a tree buffer (range path)", function()
    cur.ft = "lua"
    cur.mode = "n"
    cur.bufname = "/home/user/cfg/lua/NvimTree_settings.lua"

    command_callback({ range = 2, line1 = 4, line2 = 6 })

    assert.spy(mock_selection.send_at_mention_for_visual_selection).was_called()
    assert.same({ 4, 6 }, mock_selection.last)
    assert.spy(mock_integrations.get_selected_files_from_tree).was_not_called()
  end)

  it("does NOT misroute a 'neo-tree'-named lua file on the visual path", function()
    cur.ft = "lua"
    cur.mode = "v" -- real visual mode -> wrapper takes exit_visual_and_schedule
    cur.bufname = "/home/user/cfg/lua/plugins/_neo-tree_.lua"

    command_callback({})

    -- After <Esc> drops us to normal mode, the fixed predicate is filetype-only,
    -- so the buffer is treated as plain text and the selection is sent -- no
    -- "ClaudeCodeSend_visual->TreeAdd" error, no tree extraction.
    assert.spy(mock_selection.send_at_mention_for_visual_selection).was_called()
    assert.spy(mock_integrations.get_selected_files_from_tree).was_not_called()
  end)

  it("STILL treats a real tree filetype (neo-tree) as a tree buffer (no over-correction)", function()
    cur.ft = "neo-tree"
    cur.mode = "n"
    cur.bufname = "neo-tree filesystem [1]"

    command_callback({ range = 0 })

    -- Real explorer buffers must keep routing into tree extraction.
    assert.spy(mock_integrations.get_selected_files_from_tree).was_called()
    assert.spy(mock_selection.send_at_mention_for_visual_selection).was_not_called()
  end)
end)

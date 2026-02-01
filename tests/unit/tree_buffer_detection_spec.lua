require("tests.busted_setup")
require("tests.mocks.vim")

describe("neo-tree buffer name pattern matching", function()
  local original_require
  local command_callback
  local mock_selection

  local function setup_with_buffer_state(bufname, filetype)
    package.loaded["claudecode"] = nil
    package.loaded["claudecode.visual_commands"] = nil
    package.loaded["claudecode.integrations"] = nil
    package.loaded["claudecode.server.init"] = nil
    package.loaded["claudecode.lockfile"] = nil
    package.loaded["claudecode.config"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.diff"] = nil
    package.loaded["claudecode.selection"] = nil

    mock_selection = {
      send_at_mention_for_visual_selection = spy.new(function()
        return true
      end),
    }

    _G.vim.api.nvim_buf_get_name = spy.new(function()
      return bufname
    end)
    _G.vim.api.nvim_create_user_command = spy.new(function(name, callback, _)
      if name == "ClaudeCodeSend" then
        command_callback = callback
      end
    end)
    _G.vim.api.nvim_create_augroup = spy.new(function()
      return 1
    end)
    _G.vim.api.nvim_create_autocmd = spy.new(function()
      return 1
    end)
    _G.vim.api.nvim_replace_termcodes = function(s)
      return s
    end
    _G.vim.api.nvim_feedkeys = function() end
    _G.vim.fn.mode = function()
      return "n"
    end
    _G.vim.bo = { filetype = filetype }

    original_require = _G.require
    _G.require = function(module)
      if module == "claudecode.logger" then
        return { setup = function() end, debug = function() end, error = function() end, warn = function() end }
      elseif module == "claudecode.visual_commands" then
        return {
          create_visual_command_wrapper = function(normal_handler, _)
            return function(opts)
              return normal_handler(opts)
            end
          end,
        }
      elseif module == "claudecode.integrations" then
        return {
          get_selected_files_from_tree = spy.new(function()
            return { "/some/file.txt" }, nil
          end),
        }
      elseif module == "claudecode.selection" then
        return mock_selection
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
      elseif module == "claudecode.terminal" then
        return { setup = function() end, open = function() end, ensure_visible = function() end }
      else
        return original_require(module)
      end
    end

    local claudecode = require("claudecode")
    claudecode.setup({ auto_start = false })
    claudecode.state.server = { broadcast = spy.new(function()
      return true
    end) }
    claudecode.state.port = 12345
  end

  after_each(function()
    if original_require then
      _G.require = original_require
    end
  end)

  it("does NOT detect files with 'neo-tree' in path as tree buffer", function()
    setup_with_buffer_state("/path/to/neo-tree.nvim.lua", "lua")

    command_callback({})

    -- Should use selection module (normal file), not tree path
    assert.spy(mock_selection.send_at_mention_for_visual_selection).was_called()
  end)

  it("detects actual neo-tree buffer by name pattern", function()
    setup_with_buffer_state("neo-tree filesystem /home/user/project", "")

    command_callback({})

    -- Should NOT call selection module - detected as tree buffer
    assert.spy(mock_selection.send_at_mention_for_visual_selection).was_not_called()
  end)
end)

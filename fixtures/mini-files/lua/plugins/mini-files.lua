return {
  "echasnovski/mini.files",
  version = false,
  config = function()
    require("mini.files").setup({
      -- Customization of shown content
      content = {
        -- Predicate for which file system entries to show
        filter = nil,
        -- What prefix to show to the left of file system entry
        prefix = nil,
        -- In which order to show file system entries
        sort = nil,
      },

      -- Module mappings created only inside explorer.
      -- Use `''` (empty string) to not create one.
      mappings = {
        close = "q",
        go_in = "l",
        go_in_plus = "L",
        go_out = "h",
        go_out_plus = "H",
        reset = "<BS>",
        reveal_cwd = "@",
        show_help = "g?",
        synchronize = "=",
        trim_left = "<",
        trim_right = ">",
      },

      -- General options
      options = {
        -- Whether to delete permanently or move into module-specific trash
        permanent_delete = true,
        -- Whether to use for editing directories
        use_as_default_explorer = true,
      },

      -- Customization of explorer windows
      windows = {
        -- Maximum number of windows to show side by side
        max_number = math.huge,
        -- Whether to show preview of file/directory under cursor
        preview = false,
        -- Width of focused window
        width_focus = 50,
        -- Width of non-focused window
        width_nofocus = 15,
        -- Width of preview window
        width_preview = 25,
      },
    })

    -- Global keybindings for mini.files
    vim.keymap.set("n", "<leader>e", function()
      require("mini.files").open()
    end, { desc = "Open mini.files (current dir)" })

    vim.keymap.set("n", "<leader>E", function()
      require("mini.files").open(vim.api.nvim_buf_get_name(0))
    end, { desc = "Open mini.files (current file)" })

    vim.keymap.set("n", "-", function()
      require("mini.files").open()
    end, { desc = "Open parent directory" })

    -- Mini.files specific keybindings and autocommands
    vim.api.nvim_create_autocmd("User", {
      pattern = "MiniFilesBufferCreate",
      callback = function(args)
        local buf_id = args.data.buf_id

        -- Add buffer-local keybindings
        vim.keymap.set("n", "<C-s>", function()
          -- Split window and open file
          local cur_target = require("mini.files").get_fs_entry()
          if cur_target and cur_target.fs_type == "file" then
            require("mini.files").close()
            vim.cmd("split " .. cur_target.path)
          end
        end, { buffer = buf_id, desc = "Split and open file" })

        vim.keymap.set("n", "<C-v>", function()
          -- Vertical split and open file
          local cur_target = require("mini.files").get_fs_entry()
          if cur_target and cur_target.fs_type == "file" then
            require("mini.files").close()
            vim.cmd("vsplit " .. cur_target.path)
          end
        end, { buffer = buf_id, desc = "Vertical split and open file" })

        vim.keymap.set("n", "<C-t>", function()
          -- Open in new tab
          local cur_target = require("mini.files").get_fs_entry()
          if cur_target and cur_target.fs_type == "file" then
            require("mini.files").close()
            vim.cmd("tabnew " .. cur_target.path)
          end
        end, { buffer = buf_id, desc = "Open in new tab" })

        -- Create new file/directory
        vim.keymap.set("n", "a", function()
          local cur_target = require("mini.files").get_fs_entry()
          local path = cur_target and cur_target.path or require("mini.files").get_explorer_state().cwd
          local new_name = vim.fn.input("Create: " .. path .. "/")
          if new_name and new_name ~= "" then
            if new_name:sub(-1) == "/" then
              -- Create directory
              vim.fn.mkdir(path .. "/" .. new_name, "p")
            else
              -- Create file
              local new_file = io.open(path .. "/" .. new_name, "w")
              if new_file then
                new_file:close()
              end
            end
            require("mini.files").refresh()
          end
        end, { buffer = buf_id, desc = "Create new file/directory" })

        -- Rename file/directory
        vim.keymap.set("n", "r", function()
          local cur_target = require("mini.files").get_fs_entry()
          if cur_target then
            local old_name = vim.fn.fnamemodify(cur_target.path, ":t")
            local new_name = vim.fn.input("Rename to: ", old_name)
            if new_name and new_name ~= "" and new_name ~= old_name then
              local new_path = vim.fn.fnamemodify(cur_target.path, ":h") .. "/" .. new_name
              os.rename(cur_target.path, new_path)
              require("mini.files").refresh()
            end
          end
        end, { buffer = buf_id, desc = "Rename file/directory" })

        -- Delete file/directory
        vim.keymap.set("n", "d", function()
          local cur_target = require("mini.files").get_fs_entry()
          if cur_target then
            local confirm = vim.fn.confirm("Delete " .. cur_target.path .. "?", "&Yes\n&No", 2)
            if confirm == 1 then
              if cur_target.fs_type == "directory" then
                vim.fn.delete(cur_target.path, "rf")
              else
                vim.fn.delete(cur_target.path)
              end
              require("mini.files").refresh()
            end
          end
        end, { buffer = buf_id, desc = "Delete file/directory" })
      end,
    })

    -- Auto-close mini.files when it's the last window
    vim.api.nvim_create_autocmd("User", {
      pattern = "MiniFilesBufferUpdate",
      callback = function()
        if vim.bo.filetype == "minifiles" then
          -- Check if this is the only window left
          local windows = vim.api.nvim_list_wins()
          local minifiles_windows = 0
          for _, win in ipairs(windows) do
            local buf = vim.api.nvim_win_get_buf(win)
            if vim.api.nvim_buf_get_option(buf, "filetype") == "minifiles" then
              minifiles_windows = minifiles_windows + 1
            end
          end

          if #windows == minifiles_windows then
            vim.cmd("quit")
          end
        end
      end,
    })
  end,
}

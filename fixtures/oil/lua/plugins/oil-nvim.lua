return {
  "stevearc/oil.nvim",
  ---@module 'oil'
  ---@type oil.SetupOpts
  opts = {
    default_file_explorer = true,
    columns = {
      "icon",
      "permissions",
      "size",
      "mtime",
    },
    view_options = {
      show_hidden = false,
    },
    float = {
      padding = 2,
      max_width = 90,
      max_height = 0,
      border = "rounded",
      win_options = {
        winblend = 0,
      },
    },
  },
  -- Optional dependencies
  dependencies = { { "echasnovski/mini.icons", opts = {} } },
  -- dependencies = { "nvim-tree/nvim-web-devicons" }, -- use if you prefer nvim-web-devicons
  -- Lazy loading is not recommended because it is very tricky to make it work correctly in all situations.
  lazy = false,
  config = function(_, opts)
    require("oil").setup(opts)

    -- Global keybindings for oil
    vim.keymap.set("n", "<leader>o", "<CMD>Oil<CR>", { desc = "Open Oil (current dir)" })
    vim.keymap.set("n", "<leader>O", "<CMD>Oil --float<CR>", { desc = "Open Oil (floating)" })
    vim.keymap.set("n", "-", "<CMD>Oil<CR>", { desc = "Open parent directory" })

    -- Oil-specific keybindings (only active in Oil buffers)
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "oil",
      callback = function()
        vim.keymap.set("n", "<C-h>", "<CMD>Oil --float<CR>", { buffer = true, desc = "Open Oil float" })
        vim.keymap.set("n", "g.", function()
          require("oil").toggle_hidden()
        end, { buffer = true, desc = "Toggle hidden files" })
        vim.keymap.set("n", "<C-r>", function()
          require("oil").set_columns({ "icon", "permissions", "size", "mtime" })
        end, { buffer = true, desc = "Show detailed view" })
        vim.keymap.set("n", "<C-s>", function()
          require("oil").set_columns({ "icon" })
        end, { buffer = true, desc = "Show simple view" })
      end,
    })
  end,
}

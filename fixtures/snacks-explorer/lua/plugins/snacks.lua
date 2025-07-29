return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  opts = {
    -- Enable the explorer module
    explorer = {
      enabled = true,
      replace_netrw = true, -- Replace netrw with snacks explorer
    },
    -- Enable other useful modules for testing
    bigfile = { enabled = true },
    notifier = { enabled = true },
    quickfile = { enabled = true },
    statuscolumn = { enabled = true },
    words = { enabled = true },
  },
  keys = {
    -- Main explorer keybindings
    {
      "<leader>e",
      function()
        require("snacks").explorer()
      end,
      desc = "Explorer",
    },
    {
      "<leader>E",
      function()
        require("snacks").explorer.open()
      end,
      desc = "Explorer (open)",
    },
    {
      "<leader>fe",
      function()
        require("snacks").explorer.reveal()
      end,
      desc = "Explorer (reveal current file)",
    },

    -- Alternative keybindings for testing
    {
      "-",
      function()
        require("snacks").explorer()
      end,
      desc = "Open parent directory",
    },
    {
      "<C-n>",
      function()
        require("snacks").explorer()
      end,
      desc = "File Explorer",
    },

    -- Snacks utility keybindings for testing
    {
      "<leader>un",
      function()
        require("snacks").notifier.dismiss()
      end,
      desc = "Dismiss All Notifications",
    },
    {
      "<leader>bd",
      function()
        require("snacks").bufdelete()
      end,
      desc = "Delete Buffer",
    },
    {
      "<leader>gg",
      function()
        require("snacks").lazygit()
      end,
      desc = "Lazygit",
    },
    {
      "<leader>gb",
      function()
        require("snacks").git.blame_line()
      end,
      desc = "Git Blame Line",
    },
    {
      "<leader>gB",
      function()
        require("snacks").gitbrowse()
      end,
      desc = "Git Browse",
    },
    {
      "<leader>gf",
      function()
        require("snacks").lazygit.log_file()
      end,
      desc = "Lazygit Current File History",
    },
    {
      "<leader>gl",
      function()
        require("snacks").lazygit.log()
      end,
      desc = "Lazygit Log (cwd)",
    },
    {
      "<leader>cR",
      function()
        require("snacks").rename.rename_file()
      end,
      desc = "Rename File",
    },
    {
      "<c-/>",
      function()
        require("snacks").terminal()
      end,
      desc = "Toggle Terminal",
    },
    {
      "<c-_>",
      function()
        require("snacks").terminal()
      end,
      desc = "which_key_ignore",
    },
  },
  init = function()
    vim.api.nvim_create_autocmd("User", {
      pattern = "VeryLazy",
      callback = function()
        -- Setup some globals for easier testing
        _G.Snacks = require("snacks")
        _G.lazygit = _G.Snacks.lazygit
        _G.explorer = _G.Snacks.explorer
      end,
    })
  end,
  config = function(_, opts)
    require("snacks").setup(opts)

    -- Additional explorer-specific keybindings that activate after setup
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "snacks_picker_list", -- This is the filetype for snacks explorer
      callback = function(event)
        local buf = event.buf
        -- Custom keybindings specifically for snacks explorer buffers
        vim.keymap.set("n", "<C-v>", function()
          -- Toggle visual mode for multi-selection (this is what the PR adds support for)
          vim.cmd("normal! V")
        end, { buffer = buf, desc = "Toggle visual selection" })

        vim.keymap.set("n", "v", function()
          vim.cmd("normal! v")
        end, { buffer = buf, desc = "Visual mode" })

        vim.keymap.set("n", "V", function()
          vim.cmd("normal! V")
        end, { buffer = buf, desc = "Visual line mode" })

        -- Additional testing keybindings
        vim.keymap.set("n", "?", function()
          require("which-key").show({ buffer = buf })
        end, { buffer = buf, desc = "Show keybindings" })
      end,
    })

    -- Set up some helpful defaults for testing
    vim.opt.number = true
    vim.opt.relativenumber = true
    vim.opt.signcolumn = "yes"
    vim.opt.wrap = false

    -- Print helpful message when starting
    vim.defer_fn(function()
      print("🍿 Snacks Explorer fixture loaded!")
      print("Press <leader>e to open explorer, <leader>? for help")
      print("Use visual modes (v/V/<C-v>) in explorer for multi-file selection")
    end, 500)
  end,
}

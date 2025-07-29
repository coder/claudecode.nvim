-- Netrw keymaps setup
return {
  {
    "netrw-keymaps",
    dir = vim.fn.stdpath("config"),
    name = "netrw-keymaps",
    config = function()
      -- Set up global keymaps
      vim.keymap.set("n", "<leader>e", function()
        if vim.bo.filetype == "netrw" then
          vim.cmd("bd")
        else
          vim.cmd("Explore")
        end
      end, { desc = "Toggle file explorer" })

      vim.keymap.set("n", "<leader>E", "<cmd>Vexplore<cr>", { desc = "Open file explorer (split)" })

      -- Netrw-specific keymaps (active in netrw buffers only)
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "netrw",
        callback = function()
          local buf = vim.api.nvim_get_current_buf()
          local opts = { buffer = buf }

          vim.keymap.set("n", "h", "-", vim.tbl_extend("force", opts, { desc = "Go up directory" }))
          vim.keymap.set("n", "l", "<CR>", vim.tbl_extend("force", opts, { desc = "Enter directory/open file" }))
          vim.keymap.set("n", ".", "gh", vim.tbl_extend("force", opts, { desc = "Toggle hidden files" }))
          vim.keymap.set("n", "P", "<C-w>z", vim.tbl_extend("force", opts, { desc = "Close preview" }))
          vim.keymap.set("n", "<leader>dd", "D", vim.tbl_extend("force", opts, { desc = "Delete file/directory" }))
          vim.keymap.set("n", "<leader>r", "R", vim.tbl_extend("force", opts, { desc = "Rename file" }))
          vim.keymap.set("n", "<leader>n", "%", vim.tbl_extend("force", opts, { desc = "Create new file" }))
          vim.keymap.set("n", "<leader>N", "d", vim.tbl_extend("force", opts, { desc = "Create new directory" }))
        end,
      })
    end,
  },
}

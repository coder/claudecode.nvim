vim.api.nvim_create_autocmd("FileType", {
  pattern = "claudecode",
  callback = function(args)
    vim.keymap.set("t", "<C-q>", "<C-\\><C-n>", { buffer = args.buf, desc = "Leave terminal mode" })
  end,
})

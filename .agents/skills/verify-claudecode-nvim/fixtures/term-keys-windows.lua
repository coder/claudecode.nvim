vim.api.nvim_create_autocmd("FileType", {
  pattern = "claudecode",
  callback = function(args)
    for _, key in ipairs({ "h", "j", "k", "l" }) do
      vim.keymap.set("t", "<C-" .. key .. ">", "<C-\\><C-n><C-w>" .. key, {
        buffer = args.buf,
        desc = "Leave terminal mode and move to the window in direction " .. key,
      })
    end
  end,
})

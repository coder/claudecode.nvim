-- Neovim config for verification runs, loaded by `vcn.sh launch` via `nvim -u`.
local repo = assert(os.getenv("VCN_REPO"), "VCN_REPO is not set")
vim.opt.rtp:prepend(repo)
vim.o.swapfile = false

-- provider "none": the scripted WebSocket client plays Claude, so no `claude` CLI may start.
local opts = { terminal = { provider = "none" } }
local extra = os.getenv("VCN_SETUP")
if extra and extra ~= "" then
  opts = vim.tbl_deep_extend("force", opts, vim.json.decode(extra))
end
require("claudecode").setup(opts)

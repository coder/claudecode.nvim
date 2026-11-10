-- Neovim config for verification runs, loaded by `vcn.sh launch` via `nvim -u`.
local repo = assert(os.getenv("VCN_REPO"), "VCN_REPO is not set")
vim.opt.rtp:prepend(repo)
vim.o.swapfile = false

-- VCN_RTP: colon-separated plugin dirs to add after the repo, for example a snacks.nvim clone that a
-- `terminal.provider = "snacks"` run needs.
for _, dir in ipairs(vim.split(os.getenv("VCN_RTP") or "", ":", { plain = true, trimempty = true })) do
  vim.opt.rtp:append(dir)
end

-- provider "none": the scripted WebSocket client plays Claude, so no `claude` CLI may start.
local opts = { terminal = { provider = "none" } }
local extra = os.getenv("VCN_SETUP")
if extra and extra ~= "" then
  opts = vim.tbl_deep_extend("force", opts, vim.json.decode(extra))
end
require("claudecode").setup(opts)

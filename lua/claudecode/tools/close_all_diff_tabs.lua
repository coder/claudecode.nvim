--- Tool implementation for closing all diff tabs.

local schema = {
  description = "Close all diff tabs in the editor",
  inputSchema = {
    type = "object",
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Handles the closeAllDiffTabs tool invocation.
---Closes all diff tabs/windows in the editor.
---@return table response MCP-compliant response with content array indicating number of closed tabs.
local function handler(params)
  -- Tear down only the diffs this plugin created, resolving their pending
  -- coroutines (issue #248). claudecode.diff.active_diffs is the authoritative
  -- record of every diff claudecode opened, so it is the complete and safe scope
  -- for this tool.
  --
  -- We deliberately do NOT scan for "any window with &diff set" or buffers named
  -- like *.diff / diff:// / fugitive://: those belong to the user's own diff
  -- tools (diffview.nvim, fugitive, native :diffsplit). Claude's CLI invokes
  -- closeAllDiffTabs at the START OF EVERY TURN while an IDE is connected, so an
  -- unscoped sweep silently destroyed unrelated diffs on each prompt (issue
  -- #277). This also matches the official VS Code extension, which closes only
  -- tabs it labelled "[Claude Code] ..." -- i.e. its own diffs.
  local diff = require("claudecode.diff")
  local closed_count = diff.close_all_diffs("closeAllDiffTabs tool")

  -- Return MCP-compliant format matching VS Code extension
  return {
    content = {
      {
        type = "text",
        text = "CLOSED_" .. closed_count .. "_DIFF_TABS",
      },
    },
  }
end

return {
  name = "closeAllDiffTabs",
  schema = schema,
  handler = handler,
}

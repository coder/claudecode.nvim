-- Claude in its own Neovim, started by harness.lua spawn_claude: it connects to the plugin, sends its upgrade request,
-- and answers every ping at once until the flag file named by VWC_PEER_SILENT_FLAG exists. VWC_PEER_MODE can make one
-- ping special: "big:<n>:<bytes>" sends a text frame of that many bytes before the pong of ping n, and "late:<n>:<ms>"
-- sleeps that long first. The parent kills it.
local H = dofile(os.getenv("VWC_HARNESS"))
local frame = H.frame
local claude = H.peer(tonumber(os.getenv("VWC_PEER_PORT")))
claude.connect(function()
  claude.hello(os.getenv("VWC_PEER_TOKEN"))
end)
local flag = os.getenv("VWC_PEER_SILENT_FLAG")
local kind, at, arg = (os.getenv("VWC_PEER_MODE") or ""):match("^(%a*):?(%d*):?(%d*)$")
at, arg = tonumber(at), tonumber(arg)
local answered = 0
local timer = H.uv.new_timer()
timer:start(5, 5, function()
  local pings = claude.count(frame.OPCODE.PING)
  while answered < pings do
    answered = answered + 1
    if answered == at and kind == "big" then
      claude.send(frame.OPCODE.TEXT, string.rep("x", arg))
    elseif answered == at and kind == "late" then
      H.uv.sleep(arg)
    end
    if not H.uv.fs_stat(flag) then
      claude.send(frame.OPCODE.PONG, "")
    end
  end
end)
vim.wait(10 * 60 * 1000, function()
  return false
end)
vim.cmd("qa!")

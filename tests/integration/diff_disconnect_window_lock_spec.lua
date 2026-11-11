-- Real-Neovim check that the diffs of a Claude client that disconnects while Neovim refuses window changes close once
-- it allows them again. Neovim refuses them in the command-line window (E11) and under textlock (E565). A cleanup
-- that ran there raised partway: one openDiff call stayed unanswered and one diff stayed on screen, and nothing ran
-- the cleanup again. Busted's mock vim has neither state nor sockets, so under busted this is pending;
-- scripts/run_integration_tests_individually.sh runs it in Neovim.
-- Claude is a plain TCP client of the real server. A headless Neovim has no keyboard, so the spec enters each state
-- with nvim_feedkeys in "x" mode and does its work inside it: in a CmdwinEnter handler for the command-line window
-- (Neovim closes the window when the handlers return), and in an <expr> mapping for textlock.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("a Claude client that disconnects while Neovim refuses window changes", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("a Claude client that disconnects while Neovim refuses window changes", function()
  local claudecode = require("claudecode")
  local diff = require("claudecode.diff")
  local frame = require("claudecode.server.frame")
  local uv = vim.uv or vim.loop
  local config_dir, real_config_dir, dir, client, inbox

  local function wait_for(what, condition)
    assert(vim.wait(5000, condition, 10), what)
  end

  local function server_clients()
    return require("claudecode.server.init").state.server.clients
  end

  local function send_open_diff(id, name)
    local path = dir .. "/" .. name
    local request = vim.json.encode({
      jsonrpc = "2.0",
      id = id,
      method = "tools/call",
      params = {
        name = "openDiff",
        arguments = {
          old_file_path = path,
          new_file_path = path,
          new_file_contents = "new " .. name .. "\n",
          tab_name = "tab_" .. name,
        },
      },
    })
    client:write(frame.create_frame(frame.OPCODE.TEXT, request, true, true))
  end

  local function statuses()
    local found = {}
    for tab_name, diff_data in pairs(diff._get_active_diffs()) do
      found[tab_name] = diff_data.status
    end
    return found
  end

  ---Two openDiff calls of one client wait for the user, the second in a tab of its own.
  local function open_two_diffs()
    send_open_diff(1, "a.txt")
    wait_for("the first diff opened", function()
      return vim.tbl_count(diff._get_active_diffs()) == 1
    end)
    vim.cmd("tabnew")
    send_open_diff(2, "b.txt")
    wait_for("the second diff opened", function()
      return vim.tbl_count(diff._get_active_diffs()) == 2
    end)
  end

  ---Claude exits. Returns once the server dropped it and the cleanup it scheduled has had its turn.
  local function claude_exits()
    client:close()
    wait_for("the server dropped Claude", function()
      return next(server_clients()) == nil
    end)
    -- The server schedules its cleanup before it drops the client, and scheduled functions run in order.
    local flushed = false
    vim.schedule(function()
      flushed = true
    end)
    wait_for("the cleanup had its turn", function()
      return flushed
    end)
    -- Long enough for the cleanup's retry timer to fire in this state at least once.
    vim.wait(150)
  end

  local function assert_closed_after_the_lock(windows_before)
    local closed = vim.wait(5000, function()
      return vim.tbl_count(diff._get_active_diffs()) == 0
    end, 10)
    assert.is_true(closed, "the diffs closed once Neovim allowed window changes")
    assert.equal("", vim.v.errmsg)
    assert.equal(0, vim.tbl_count(_G.claude_deferred_responses or {}), "no openDiff call is left waiting")
    assert.equal(windows_before, #vim.api.nvim_list_wins(), "no diff window is left on screen")
  end

  before_each(function()
    real_config_dir = vim.env.CLAUDE_CONFIG_DIR
    config_dir = vim.fn.tempname()
    vim.fn.mkdir(config_dir, "p")
    vim.env.CLAUDE_CONFIG_DIR = config_dir
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    for _, name in ipairs({ "a.txt", "b.txt" }) do
      vim.fn.writefile({ "old " .. name }, dir .. "/" .. name)
    end
    claudecode.setup({ auto_start = false, log_level = "error", terminal = { provider = "none" } })
    assert.is_true(claudecode.start(false))
    inbox = ""
    client = uv.new_tcp()
    client:connect("127.0.0.1", claudecode.state.port, function(err)
      assert(not err, err)
      client:read_start(function(_, data)
        inbox = inbox .. (data or "")
      end)
      client:write(table.concat({
        "GET / HTTP/1.1",
        "Host: 127.0.0.1",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. claudecode.state.auth_token,
        "",
        "",
      }, "\r\n"))
    end)
    wait_for("the server accepted Claude", function()
      return inbox:find("^HTTP/1.1 101") ~= nil and next(server_clients()) ~= nil
    end)
    vim.v.errmsg = ""
  end)

  after_each(function()
    if client and not client:is_closing() then
      client:close()
    end
    pcall(claudecode.stop)
    diff._cleanup_all_active_diffs("test cleanup")
    vim.env.CLAUDE_CONFIG_DIR = real_config_dir
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    vim.fn.delete(config_dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  it("in the command-line window: its diffs close after the user leaves the window, with no error", function()
    local windows_before = #vim.api.nvim_list_wins()
    open_two_diffs()

    local window_type, in_window
    vim.api.nvim_create_autocmd("CmdwinEnter", {
      once = true,
      callback = function()
        window_type = vim.fn.getcmdwintype()
        claude_exits()
        in_window = statuses()
      end,
    })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q:", true, false, true), "x", false)

    assert.equal(":", window_type, "the user was in the command-line window when Claude left")
    assert.same({ ["tab_a.txt"] = "pending", ["tab_b.txt"] = "pending" }, in_window, "the cleanup waited")
    assert_closed_after_the_lock(windows_before + 1)
  end)

  it("under textlock: its diffs close after the textlock ends, with no error", function()
    local windows_before = #vim.api.nvim_list_wins()
    open_two_diffs()

    local in_textlock, refused
    vim.keymap.set("n", "<Plug>(claudecode-test-textlock)", function()
      refused = select(2, pcall(vim.api.nvim_set_current_win, vim.api.nvim_get_current_win()))
      claude_exits()
      in_textlock = statuses()
      return ""
    end, { expr = true })
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<Plug>(claudecode-test-textlock)", true, false, true),
      "x",
      false
    )
    vim.keymap.del("n", "<Plug>(claudecode-test-textlock)")

    assert.is_truthy(tostring(refused):find("E565"), "the mapping ran under textlock")
    assert.same({ ["tab_a.txt"] = "pending", ["tab_b.txt"] = "pending" }, in_textlock, "the cleanup waited")
    assert_closed_after_the_lock(windows_before + 1)
  end)
end)

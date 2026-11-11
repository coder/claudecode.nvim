-- Real-Neovim checks of the paths that tear a diff down while Neovim refuses window changes, besides the disconnect
-- cleanup. Busted's mock vim has neither state nor sockets, so under busted this is pending;
-- scripts/run_integration_tests_individually.sh runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("paths that tear a diff down while Neovim refuses window changes", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("paths that tear a diff down while Neovim refuses window changes", function()
  local claudecode = require("claudecode")
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local frame = require("claudecode.server.frame")
  local window_lock = require("tests.helpers.window_lock")
  local uv = vim.uv or vim.loop
  local config_dir, real_config_dir, dir, connections

  local function wait_for(what, condition)
    assert(vim.wait(5000, condition, 10), what)
  end

  local function server_clients()
    return require("claudecode.server.init").state.server.clients
  end

  -- Neovim 0.8's luv crashes in uv.walk, so count the timers that `fn` arms with vim.defer_fn instead.
  local function timers_armed_by(fn)
    local armed, defer_fn = 0, vim.defer_fn
    vim.defer_fn = function(...)
      armed = armed + 1
      return defer_fn(...)
    end
    local ok, err = pcall(fn)
    vim.defer_fn = defer_fn
    assert(ok, err)
    return armed
  end

  local function connect(handshake)
    local before = vim.tbl_count(server_clients())
    local connection = { handle = uv.new_tcp(), inbox = "" }
    table.insert(connections, connection)
    connection.handle:connect("127.0.0.1", claudecode.state.port, function(err)
      assert(not err, err)
      connection.handle:read_start(function(_, data)
        connection.inbox = connection.inbox .. (data or "")
      end)
      if handshake then
        connection.handle:write(table.concat({
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
      end
    end)
    wait_for("the server accepted the connection", function()
      return vim.tbl_count(server_clients()) > before and (not handshake or connection.inbox:find("^HTTP/1.1 101"))
    end)
    return connection
  end

  local request_id = 0
  local function send_open_diff(connection, name, tab_name)
    request_id = request_id + 1
    local path = dir .. "/" .. name
    vim.fn.writefile({ "old " .. name }, path)
    connection.handle:write(frame.create_frame(
      frame.OPCODE.TEXT,
      vim.json.encode({
        jsonrpc = "2.0",
        id = request_id,
        method = "tools/call",
        params = {
          name = "openDiff",
          arguments = {
            old_file_path = path,
            new_file_path = path,
            new_file_contents = "new " .. name .. "\n",
            tab_name = tab_name,
          },
        },
      }),
      true,
      true
    ))
    return request_id
  end

  local function statuses()
    local found = {}
    for tab_name, diff_data in pairs(diff._get_active_diffs()) do
      found[tab_name] = diff_data.status
    end
    return found
  end

  local function open_two_diffs(connection)
    send_open_diff(connection, "a.txt", "tab_a.txt")
    wait_for("the first diff opened", function()
      return vim.tbl_count(diff._get_active_diffs()) == 1
    end)
    vim.cmd("tabnew")
    send_open_diff(connection, "b.txt", "tab_b.txt")
    wait_for("the second diff opened", function()
      return vim.tbl_count(diff._get_active_diffs()) == 2
    end)
  end

  local function assert_closed_after_the_lock(windows_before)
    local closed = vim.wait(5000, function()
      return vim.tbl_count(diff._get_active_diffs()) == 0
    end, 10)
    assert.is_true(closed, "the diffs closed once Neovim allowed window changes: " .. vim.inspect(statuses()))
    assert.equal(windows_before, #vim.api.nvim_list_wins(), "no diff window is left on screen")
  end

  before_each(function()
    real_config_dir = vim.env.CLAUDE_CONFIG_DIR
    config_dir = vim.fn.tempname()
    vim.fn.mkdir(config_dir, "p")
    vim.env.CLAUDE_CONFIG_DIR = config_dir
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.o.columns, vim.o.lines = 160, 40
    claudecode.setup({ auto_start = false, log_level = "error", terminal = { provider = "none" } })
    assert.is_true(claudecode.start(false))
    connections = {}
    vim.v.errmsg = ""
  end)

  after_each(function()
    for _, connection in ipairs(connections) do
      if not connection.handle:is_closing() then
        connection.handle:close()
      end
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

  for _, lock in ipairs(window_lock.states) do
    describe("when " .. lock.name, function()
      it("the server stops without raising, answers both calls, and the diffs close after the lock", function()
        local claude = connect(true)
        local windows_before = #vim.api.nvim_list_wins()
        open_two_diffs(claude)

        local stopped, stop_error, in_lock
        lock.enter(function()
          stopped, stop_error = pcall(claudecode.stop)
          in_lock = { statuses = statuses(), running = claudecode.state.server ~= nil }
        end)

        assert.is_true(stopped, "the server stop raised: " .. tostring(stop_error))
        assert.is_false(in_lock.running, "the server is stopped")
        assert.same(
          { ["tab_a.txt"] = "rejected", ["tab_b.txt"] = "rejected" },
          in_lock.statuses,
          "each call has its answer"
        )
        assert_closed_after_the_lock(windows_before + 1)
        assert.equal("", vim.v.errmsg)
        assert.is_true(claudecode.start(false), "the server starts again after the stop")
      end)

      it("a new client's openDiff replaces a gone client's diff: the old diff closes after the lock", function()
        local gone = connect(true)
        local windows_before = #vim.api.nvim_list_wins()
        send_open_diff(gone, "a.txt", "tab_shared")
        wait_for("the first diff opened", function()
          return vim.tbl_count(diff._get_active_diffs()) == 1
        end)
        local fresh = connect(true)
        local clients_before = vim.tbl_count(server_clients())

        local in_lock, reply
        lock.enter(function()
          gone.handle:close()
          wait_for("the server dropped the gone client", function()
            return vim.tbl_count(server_clients()) == clients_before - 1
          end)
          local id = send_open_diff(fresh, "b.txt", "tab_shared")
          wait_for("the new client got its answer", function()
            return fresh.inbox:find('"id":' .. id, 1, true) ~= nil
          end)
          in_lock = statuses()
          reply = fresh.inbox
        end)

        assert.is_truthy(reply:find('"error"', 1, true), "the new call got an error answer while windows were locked")
        assert.same({ tab_shared = "rejected" }, in_lock, "the old call has its answer and its diff waits")
        assert_closed_after_the_lock(windows_before)
        assert.is_nil(vim.v.errmsg:find("diffoff", 1, true), "the cleanup of the old diff raised: " .. vim.v.errmsg)
      end)

      it("many cleanups waiting at once share one retry timer", function()
        tools.register_all()
        _G.claude_deferred_responses = {}
        for index = 1, 20 do
          local name = "many" .. index .. ".txt"
          local path = dir .. "/" .. name
          vim.fn.writefile({ "old" }, path)
          local call = tools.handle_invoke({ id = "many" }, {
            name = "openDiff",
            arguments = { old_file_path = path, new_file_path = path, new_file_contents = "new\n", tab_name = name },
          })
          assert.is_true(call._deferred, "openDiff waits for the user")
          _G.claude_deferred_responses[tostring(call.coroutine)] = function() end
        end

        local closed, timers
        lock.enter(function()
          timers = timers_armed_by(function()
            closed = diff.close_pending_diffs("test")
          end)
        end)

        assert.equal(20, closed, "the bulk close reached every diff")
        assert.is_true(timers <= 1, "one retry timer for 20 cleanups, not one each: " .. timers)
        assert.equal(0, vim.tbl_count(_G.claude_deferred_responses), "every call has its answer")
        local gone = vim.wait(5000, function()
          return vim.tbl_count(diff._get_active_diffs()) == 0
        end, 10)
        assert.is_true(gone, "all 20 diffs closed after the lock")
      end)
    end)
  end

  it("many connections that close before their handshake leave no timer each", function()
    local connection_count = 50
    local early = {}
    for _ = 1, connection_count do
      table.insert(early, connect(false))
    end

    local timers
    window_lock.in_command_line_window(function()
      timers = timers_armed_by(function()
        for _, connection in ipairs(early) do
          connection.handle:close()
        end
        wait_for("the server dropped every connection", function()
          return vim.tbl_count(server_clients()) == 0
        end)
        vim.wait(150)
      end)
    end)

    assert.is_true(timers <= 1, connection_count .. " closed connections armed " .. timers .. " timers")
  end)
end)

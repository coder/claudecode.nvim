-- Real-Neovim check of the answer that each openDiff call gets in four exits: `:qa!`, SIGTERM, a buffer that deletes
-- itself in its own BufUnload, and `:qa!` inside a `nested = true` ClaudeCodeDiffOpened handler. README.md lists the
-- answers under Global Invariants, in "Exit answers". This spec does not run SIGHUP, SIGKILL, a quit from a
-- non-nested autocmd or :ClaudeCodeStop, and it does not check the close codes or the ClaudeCodeDiffClosed order.
-- Neovim fires BufUnload for each loaded buffer at exit, and the proposal buffers' autocmds reject their diffs. That
-- loop stops once an autocmd deletes the buffer it fired for: the reject of a new-file diff with the default
-- `on_new_file_reject = "keep_empty"`, in a tab the diff did not open, deletes its proposal buffer, and another
-- plugin's buffer can delete itself. SIGTERM runs VimLeavePre without the loop. The diffs behind it get no BufUnload,
-- so the VimLeavePre autocmd of diff.lua must reject them. A child Neovim does the exit, because it ends the process.
-- Mock vim cannot run an exit, so under busted this is pending.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff at exit", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openDiff at exit", function()
  local dir

  -- The child opens each step's diff in a coroutine, as the server does, and logs every answer its sender gets.
  local child_script = [[
    local log_path = vim.env.EXIT_LOG
    local function log(line)
      local file = assert(io.open(log_path, "a"))
      file:write(line, "\n")
      file:close()
    end
    require("claudecode").setup({
      auto_start = false,
      terminal = { provider = "none" },
      diff_opts = { layout = vim.env.EXIT_LAYOUT, on_new_file_reject = vim.env.EXIT_REJECT },
    })
    local diff = require("claudecode.diff")
    if vim.env.EXIT_DELETER == "1" then
      local other = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(other, 0, -1, false, { "another plugin's buffer" })
      vim.api.nvim_create_autocmd("BufUnload", {
        buffer = other,
        callback = function(args)
          vim.api.nvim_buf_delete(args.buf, { force = true })
        end,
      })
    end
    _G.claude_deferred_responses = {}
    for step in vim.env.EXIT_STEPS:gmatch("[^,]+") do
      local name, kind = step:match("^(.-):(.*)$")
      local path = vim.env.EXIT_DIR .. "/" .. name
      if kind == "old" then
        vim.fn.writefile({ "old line" }, path)
      else
        os.remove(path)
      end
      local co = coroutine.create(function()
        return diff.open_diff_blocking(path, path, "new line\n", "tab_" .. name, nil)
      end)
      local ok, err = coroutine.resume(co)
      local resumed = "resume " .. name .. " ok=" .. tostring(ok) .. " status=" .. coroutine.status(co)
      log(resumed .. (ok and "" or " " .. tostring(err)))
      _G.claude_deferred_responses[tostring(co)] = function(response)
        local text = response.content and response.content[1].text or vim.inspect(response)
        log("answer " .. name .. " " .. tostring(text))
      end
    end
    vim.defer_fn(function()
      if vim.env.EXIT_QUIT == "sigterm" then
        vim.loop.kill(vim.fn.getpid(), 15)
        return
      end
      vim.cmd("qa!")
    end, 100)
  ]]

  -- The same steps as requests, through the server's own message handler. The server answers through
  -- `send_response`, which the child replaces with a log line, as it has no client on a socket.
  local setup_exit_script = [[
    local log_path = vim.env.EXIT_LOG
    local function log(line)
      local file = assert(io.open(log_path, "a"))
      file:write(line, "\n")
      file:close()
    end
    require("claudecode").setup({
      auto_start = true,
      terminal = { provider = "none" },
      diff_opts = { layout = vim.env.EXIT_LAYOUT },
    })
    local server = require("claudecode.server.init")
    server.send_response = function(_, id, result, error_data)
      log("response " .. id .. " " .. (result and result.content[1].text or ("error " .. error_data.code)))
    end
    vim.api.nvim_create_autocmd("User", {
      pattern = "ClaudeCodeDiffOpened",
      nested = true,
      callback = function(args)
        if args.data.tab_name == "tab_" .. vim.env.EXIT_QUIT_IN then
          vim.cmd("qa!")
        end
      end,
    })
    local id = 0
    for step in vim.env.EXIT_STEPS:gmatch("[^,]+") do
      local name, kind = step:match("^(.-):(.*)$")
      local path = vim.env.EXIT_DIR .. "/" .. name
      if kind == "old" then
        vim.fn.writefile({ "old line" }, path)
      else
        os.remove(path)
      end
      id = id + 1
      server._handle_message({ id = "stub" }, vim.json.encode({
        jsonrpc = "2.0",
        id = id,
        method = "tools/call",
        params = {
          name = "openDiff",
          arguments = {
            old_file_path = path,
            new_file_path = path,
            new_file_contents = "new line\n",
            tab_name = "tab_" .. name,
          },
        },
      }))
    end
  ]]

  ---Run `source` in a child Neovim with `env`, and return the lines it logged and its exit code.
  local function run_child(source, env)
    local script = dir .. "/child.lua"
    local log_path = dir .. "/answers.log"
    vim.fn.writefile(vim.split(source, "\n"), script)
    vim.fn.delete(log_path)
    env.EXIT_LOG = log_path
    env.EXIT_DIR = dir
    -- The child starts a server in some scenarios: its lock file goes to this folder, not to the user's.
    env.CLAUDE_CONFIG_DIR = dir .. "/claude"
    local job = vim.fn.jobstart({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "--cmd",
      "set rtp^=" .. vim.fn.getcwd(),
      "-c",
      "luafile " .. vim.fn.fnameescape(script),
    }, { env = env })
    assert.is_true(job > 0, "could not start a child Neovim")
    local code = vim.fn.jobwait({ job }, 20000)[1]
    if code == -1 then
      vim.fn.jobstop(job)
    end
    local lines = vim.fn.filereadable(log_path) == 1 and vim.fn.readfile(log_path) or {}
    return lines, code
  end

  ---Open the diffs of `steps` ("name:new" or "name:old", in order) in a child Neovim, end it with :qa! (or SIGTERM),
  ---and return the answers that its senders got and its exit code.
  local function exit_with(steps, layout, reject, deleter, quit)
    return run_child(child_script, {
      EXIT_LAYOUT = layout,
      EXIT_REJECT = reject,
      EXIT_STEPS = table.concat(steps, ","),
      EXIT_DELETER = deleter and "1" or "0",
      EXIT_QUIT = quit or "qa",
    })
  end

  ---Send the openDiff of each step to the child's server as a request, and have a `nested = true` ClaudeCodeDiffOpened
  ---handler run :qa! during the setup of the step named `quit_in`. The call has no response sender yet, so the child
  ---logs what the server sends for each request id.
  local function exit_in_opened_handler(steps, quit_in, layout)
    return run_child(setup_exit_script, {
      EXIT_LAYOUT = layout,
      EXIT_STEPS = table.concat(steps, ","),
      EXIT_QUIT_IN = quit_in,
    })
  end

  local function answers_by_name(lines)
    local answers = {}
    for _, line in ipairs(lines) do
      local name, text = line:match("^answer (%S+) (.*)$")
      if name then
        answers[name] = answers[name] or {}
        table.insert(answers[name], text)
      end
    end
    return answers
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  local scenarios = {
    { name = "one existing file", steps = { "a.txt:old" } },
    { name = "a new file, then an existing file", steps = { "new1.txt:new", "b.txt:old" } },
    { name = "an existing file, then a new file", steps = { "a.txt:old", "new2.txt:new" } },
    { name = "two new files", steps = { "new1.txt:new", "new2.txt:new" } },
    { name = "a new file, an existing file, and a new file", steps = { "new1.txt:new", "b.txt:old", "new2.txt:new" } },
  }
  local layouts = { "vertical", "unified" }
  local rejects = { "keep_empty", "close_window" }

  for _, layout in ipairs(layouts) do
    it(("answers each pending diff when SIGTERM ends Neovim (%s layout)"):format(layout), function()
      local lines = exit_with({ "new1.txt:new", "b.txt:old" }, layout, "keep_empty", false, "sigterm")
      local answers = answers_by_name(lines)
      assert.same({ "DIFF_REJECTED" }, answers["new1.txt"], table.concat(lines, "\n"))
      assert.same({ "DIFF_REJECTED" }, answers["b.txt"], table.concat(lines, "\n"))
    end)
    it(("answers one diff that another plugin's buffer kept from its BufUnload (%s layout)"):format(layout), function()
      local lines, code = exit_with({ "a.txt:old" }, layout, "keep_empty", true)
      assert.equal(0, code, "the child exited with :qa!\n" .. table.concat(lines, "\n"))
      assert.same({ "DIFF_REJECTED" }, answers_by_name(lines)["a.txt"], table.concat(lines, "\n"))
    end)
  end

  ---The answers that the server sent, by request id.
  local function responses_by_id(lines)
    local responses = {}
    for _, line in ipairs(lines) do
      local id, text = line:match("^response (%d+) (.*)$")
      if id then
        id = tonumber(id)
        responses[id] = responses[id] or {}
        table.insert(responses[id], text)
      end
    end
    return responses
  end

  for _, layout in ipairs(layouts) do
    it(("answers the call whose setup was running when a handler quit Neovim (%s layout)"):format(layout), function()
      local lines = exit_in_opened_handler({ "new1.txt:new", "b.txt:old" }, "b.txt", layout)

      local responses = responses_by_id(lines)
      local log = table.concat(lines, "\n")
      assert.same({ "DIFF_REJECTED" }, responses[1], log)
      assert.same({ "error -32603" }, responses[2], log)
    end)
    it(("answers the only call when a handler quit Neovim during its setup (%s layout)"):format(layout), function()
      local lines = exit_in_opened_handler({ "a.txt:old" }, "a.txt", layout)

      assert.same({ "error -32603" }, responses_by_id(lines)[1], table.concat(lines, "\n"))
    end)
  end

  for _, layout in ipairs(layouts) do
    for _, reject in ipairs(rejects) do
      for _, scenario in ipairs(scenarios) do
        local title = ("answers each of %s with DIFF_REJECTED once (%s layout, on_new_file_reject = %s)"):format(
          scenario.name,
          layout,
          reject
        )
        it(title, function()
          local lines, code = exit_with(scenario.steps, layout, reject)

          assert.equal(0, code, "the child exited with :qa!\n" .. table.concat(lines, "\n"))
          local answers = answers_by_name(lines)
          for _, step in ipairs(scenario.steps) do
            local name = step:match("^(.-):")
            assert.same(
              { "DIFF_REJECTED" },
              answers[name],
              ("openDiff of %s must get one DIFF_REJECTED. Log:\n%s"):format(name, table.concat(lines, "\n"))
            )
          end
        end)
      end
    end
  end
end)

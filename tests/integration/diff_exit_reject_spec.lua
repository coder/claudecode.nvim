-- Real-Neovim check that `:qa!` answers every openDiff that is still pending, with DIFF_REJECTED, exactly once.
-- Neovim fires BufUnload for each loaded buffer at exit, and the proposal buffers' autocmds reject their diffs. That
-- loop stops once an autocmd deletes the buffer it fired for, and the reject of a new-file diff with the default
-- `on_new_file_reject = "keep_empty"` deletes its proposal buffer. The diffs behind it get no BufUnload, so the
-- VimLeavePre autocmd of diff.lua must answer them. A child Neovim does the exit, because it ends the process.
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
      log("resume " .. name .. " ok=" .. tostring(ok) .. " status=" .. coroutine.status(co) .. (ok and "" or " " .. tostring(err)))
      _G.claude_deferred_responses[tostring(co)] = function(response)
        log("answer " .. name .. " " .. tostring(response.content and response.content[1].text or vim.inspect(response)))
      end
    end
    vim.defer_fn(function()
      vim.cmd("qa!")
    end, 100)
  ]]

  ---Open the diffs of `steps` ("name:new" or "name:old", in order) in a child Neovim, quit it with :qa!, and return
  ---the answers that its senders got and its exit code.
  local function exit_with(steps, layout, reject)
    local script = dir .. "/child.lua"
    local log_path = dir .. "/answers.log"
    vim.fn.writefile(vim.split(child_script, "\n"), script)
    vim.fn.delete(log_path)
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
    }, {
      env = {
        EXIT_LOG = log_path,
        EXIT_DIR = dir,
        EXIT_LAYOUT = layout,
        EXIT_REJECT = reject,
        EXIT_STEPS = table.concat(steps, ","),
      },
    })
    assert.is_true(job > 0, "could not start a child Neovim")
    local code = vim.fn.jobwait({ job }, 20000)[1]
    if code == -1 then
      vim.fn.jobstop(job)
    end
    local lines = vim.fn.filereadable(log_path) == 1 and vim.fn.readfile(log_path) or {}
    return lines, code
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
    for _, reject in ipairs(rejects) do
      for _, scenario in ipairs(scenarios) do
        local title = ("answers each of %s with DIFF_REJECTED once (%s layout, on_new_file_reject = %s)"):format(
          scenario.name,
          layout,
          reject
        )
        -- The unified layout needs Neovim 0.9. The split layout bug is the same on 0.8.
        local runs_here = layout ~= "unified" or vim.fn.has("nvim-0.9") == 1
        local define = runs_here and it or pending
        define(title, function()
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

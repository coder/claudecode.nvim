--- A stand-in for `vim.cmd`. Neovim's `vim.cmd` runs a string when it is called, and gives a function for each command
--- name, as in `vim.cmd.edit(path)` or `vim.cmd.edit({ path, mods = { noswapfile = true } })`. Both forms reach `run`
--- as one string, the second as "<mods> <name> <args>", so a spec that records the strings sees the same string for a
--- command in either form.
---@param run fun(command: string): any
---@return table cmd
return function(run)
  return setmetatable({}, {
    __call = function(_, command)
      return run(command)
    end,
    __index = function(_, name)
      return function(...)
        local args, parts = { ... }, {}
        if #args == 1 and type(args[1]) == "table" then
          args = args[1]
          for mod, on in pairs(args.mods or {}) do
            if on == true then
              parts[#parts + 1] = mod
            end
          end
          table.sort(parts)
        end
        parts[#parts + 1] = name
        for _, arg in ipairs(args) do
          parts[#parts + 1] = arg
        end
        return run(table.concat(parts, " "))
      end
    end,
  })
end

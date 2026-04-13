local M = {}

local aliases = {
  CodeDiffOpen = "CorkDiffOpen",
  CodeDiffClose = "CorkDiffClose",
  CodeDiffFileSelect = "CorkDiffFileSelect",
  CodeDiffVirtualFileLoaded = "CorkDiffVirtualFileLoaded",
}

local reverse_aliases = {}
for old_name, new_name in pairs(aliases) do
  reverse_aliases[new_name] = old_name
end

function M.emit(pattern, data)
  local emitted = {}

  local function fire(name)
    if emitted[name] then
      return
    end

    emitted[name] = true
    vim.api.nvim_exec_autocmds("User", {
      pattern = name,
      modeline = false,
      data = data,
    })
  end

  fire(pattern)

  local alias = aliases[pattern] or reverse_aliases[pattern]
  if alias then
    fire(alias)
  end
end

return M

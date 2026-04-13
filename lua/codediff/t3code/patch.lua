local M = {}

local util = require("codediff.t3code.util")

local function strip_prefix(path)
  if not path then
    return nil
  end
  if path == "/dev/null" then
    return nil
  end
  return path:gsub('^"', ""):gsub('"$', ""):gsub("^[ab]/", "")
end

function M.parse_files(diff_text)
  local entries = {}
  local current = nil

  local function flush_current()
    if not current then
      return
    end
    if current.status == "D" then
      current.path = current.old_path or current.path
    end
    if current.status ~= "R" then
      current.old_path = nil
    end
    if current.path then
      table.insert(entries, current)
    end
    current = nil
  end

  for _, line in ipairs(util.to_lines(diff_text)) do
    if vim.startswith(line, "diff --git ") then
      flush_current()
      local old_path, new_path = line:match("^diff %-%-git a/(.-) b/(.-)$")
      current = {
        status = "M",
        old_path = strip_prefix(old_path),
        path = strip_prefix(new_path),
      }
    elseif current and vim.startswith(line, "new file mode ") then
      current.status = "A"
      current.old_path = nil
    elseif current and vim.startswith(line, "deleted file mode ") then
      current.status = "D"
    elseif current then
      local rename_from = line:match("^rename from (.+)$")
      if rename_from then
        current.status = "R"
        current.old_path = rename_from
      else
        local rename_to = line:match("^rename to (.+)$")
        if rename_to then
          current.path = rename_to
        end
      end
    end
  end

  flush_current()
  return entries
end

function M.find_entry_for_path(entries, path)
  for _, entry in ipairs(entries or {}) do
    if entry.path == path or entry.old_path == path then
      return entry
    end
  end
  return nil
end

return M

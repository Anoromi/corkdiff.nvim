local M = {}

function M.system(cmd, opts)
  opts = opts or {}
  if not vim.system then
    return nil, "vim.system is required for t3code integration"
  end

  local result = vim.system(cmd, {
    cwd = opts.cwd,
    text = true,
    stdin = opts.stdin,
  }):wait()

  if result.code ~= 0 then
    local stderr = result.stderr and vim.trim(result.stderr) or ""
    if stderr == "" then
      stderr = "command failed"
    end
    return nil, stderr
  end

  return result.stdout or "", nil
end

function M.readable_json(stdout)
  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok then
    return nil, decoded
  end
  return decoded, nil
end

function M.path_join(...)
  return table.concat({ ... }, "/"):gsub("//+", "/")
end

function M.file_exists(path)
  return vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1
end

function M.dirname(path)
  return vim.fn.fnamemodify(path, ":h")
end

function M.basename(path)
  return vim.fn.fnamemodify(path, ":t")
end

function M.to_lines(text)
  if not text or text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

function M.deepcopy(value)
  return vim.deepcopy(value)
end

return M

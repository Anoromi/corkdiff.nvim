local M = {}

local diff = require("codediff.core.diff")
local util = require("codediff.t3code.util")

local DIFF_OPTIONS = {
  max_computation_time_ms = 5000,
  ignore_trim_whitespace = false,
  compute_moves = false,
}

local function run_git(repo_root, args, opts)
  local cmd = { "git", "-C", repo_root }
  vim.list_extend(cmd, args)
  return util.system(cmd, opts)
end

local function is_zero_oid(oid)
  return type(oid) == "string" and oid:match("^0+$") ~= nil
end

local function normalize_oid(oid)
  if not oid or oid == "" or is_zero_oid(oid) then
    return nil
  end
  return oid
end

local function split_nul(text)
  local parts = {}
  local start = 1
  while true do
    local stop = string.find(text, "\0", start, true)
    if not stop then
      break
    end
    parts[#parts + 1] = string.sub(text, start, stop - 1)
    start = stop + 1
  end
  if start <= #text then
    parts[#parts + 1] = string.sub(text, start)
  end
  return parts
end

local function parse_name_status_line(line)
  local parts = vim.split(line, "\t", { plain = true })
  if #parts < 2 then
    return nil
  end
  local status = parts[1]:sub(1, 1)
  if status == "R" and #parts >= 3 then
    return {
      status = "R",
      old_path = parts[2],
      path = parts[3],
    }
  end
  return {
    status = status,
    old_path = nil,
    path = parts[2],
  }
end

function M.is_git_repo(repo_root)
  local _, err = run_git(repo_root, { "rev-parse", "--show-toplevel" })
  return err == nil
end

function M.checkpoint_ref_for_turn(thread_id, turn_count)
  local encoded = vim.base64.encode(thread_id):gsub("+", "-"):gsub("/", "_"):gsub("=", "")
  return string.format("refs/t3/checkpoints/%s/turn/%d", encoded, turn_count)
end

function M.read_name_status(repo_root, from_ref, to_ref)
  local output, err = run_git(repo_root, { "diff", "--name-status", "-M", from_ref, to_ref, "--" })
  if not output then
    return nil, err
  end

  local entries = {}
  for _, line in ipairs(util.to_lines(output)) do
    local parsed = parse_name_status_line(line)
    if parsed then
      table.insert(entries, parsed)
    end
  end
  return entries, nil
end

local function parse_raw_header(header)
  local old_mode, new_mode, old_oid, new_oid, status_score =
    header:match("^:([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+)$")
  if not old_mode then
    return nil
  end
  return {
    old_mode = old_mode,
    new_mode = new_mode,
    old_oid = normalize_oid(old_oid),
    new_oid = normalize_oid(new_oid),
    status = status_score:sub(1, 1),
    score = tonumber(status_score:sub(2)) or nil,
  }
end

function M.read_raw_diff(repo_root, from_ref, to_ref)
  local output, err = run_git(repo_root, { "diff", "--raw", "-z", "--no-abbrev", "-M", from_ref, to_ref, "--" })
  if not output then
    return nil, err
  end

  local records = split_nul(output)
  local entries = {}
  local index = 1
  while index <= #records do
    local parsed = parse_raw_header(records[index])
    index = index + 1
    if parsed then
      local old_or_path = records[index]
      index = index + 1
      if parsed.status == "R" or parsed.status == "C" then
        parsed.old_path = old_or_path
        parsed.path = records[index]
        index = index + 1
      else
        parsed.old_path = nil
        parsed.path = old_or_path
      end
      entries[#entries + 1] = parsed
    end
  end

  return entries, nil
end

function M.index_raw_entries(entries)
  local index = {
    by_path = {},
    by_old_path = {},
  }
  for _, entry in ipairs(entries or {}) do
    if entry.path then
      index.by_path[entry.path] = entry
    end
    if entry.old_path then
      index.by_old_path[entry.old_path] = entry
    end
  end
  return index
end

function M.find_entry_for_path(entries, path)
  if not path then
    return nil
  end
  for _, entry in ipairs(entries or {}) do
    if entry.path == path or entry.old_path == path then
      return entry
    end
  end
  return nil
end

function M.find_indexed_entry(index, path)
  if not index or not path then
    return nil
  end
  return (index.by_path and index.by_path[path]) or (index.by_old_path and index.by_old_path[path]) or nil
end

function M.read_file_lines(repo_root, ref, path)
  if not path or path == "" then
    return {}, nil
  end
  local stdout, err = run_git(repo_root, { "show", string.format("%s:%s", ref, path) })
  if not stdout then
    return nil, err
  end
  return util.to_lines(stdout), nil
end

function M.read_blobs(repo_root, oids)
  local unique = {}
  local ordered = {}
  for _, oid in ipairs(oids or {}) do
    oid = normalize_oid(oid)
    if oid and not unique[oid] then
      unique[oid] = true
      ordered[#ordered + 1] = oid
    end
  end
  if #ordered == 0 then
    return {}, nil
  end

  local stdout, err = run_git(repo_root, { "cat-file", "--batch" }, {
    stdin = table.concat(ordered, "\n") .. "\n",
    text = false,
  })
  if not stdout then
    return nil, err
  end

  local blobs = {}
  local pos = 1
  while pos <= #stdout do
    local header_end = string.find(stdout, "\n", pos, true)
    if not header_end then
      break
    end
    local header = string.sub(stdout, pos, header_end - 1)
    pos = header_end + 1

    local oid, kind, size = header:match("^(%S+) (%S+) (%d+)$")
    if not oid then
      oid, kind = header:match("^(%S+) (%S+)$")
      if kind == "missing" then
        return nil, "missing git object: " .. tostring(oid)
      end
      return nil, "failed to parse git cat-file header: " .. header
    end

    size = tonumber(size)
    if kind ~= "blob" then
      return nil, "git object is not a blob: " .. tostring(oid)
    end
    if not size or pos + size - 1 > #stdout then
      return nil, "truncated git cat-file output for " .. tostring(oid)
    end

    local content = string.sub(stdout, pos, pos + size - 1)
    blobs[oid] = util.to_lines(content)
    pos = pos + size
    if string.sub(stdout, pos, pos) == "\n" then
      pos = pos + 1
    end
  end

  return blobs, nil
end

function M.read_current_lines(abs_path, opts)
  opts = opts or {}
  local bufnr = vim.fn.bufnr(abs_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
    if vim.api.nvim_buf_is_loaded(bufnr) then
      return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
    end
    if opts.load_unloaded_buffer ~= false then
      vim.fn.bufload(bufnr)
      return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
    end
  end
  if vim.fn.filereadable(abs_path) == 1 then
    if opts.load_unloaded_buffer == false then
      return vim.fn.readfile(abs_path), nil
    end
    local file_buf = vim.fn.bufadd(abs_path)
    vim.fn.bufload(file_buf)
    return vim.api.nvim_buf_get_lines(file_buf, 0, -1, false), file_buf
  end
  return {}, nil
end

function M.compute_diff(original_lines, modified_lines)
  return diff.compute_diff(original_lines, modified_lines, DIFF_OPTIONS)
end

return M

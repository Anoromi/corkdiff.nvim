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

function M.read_current_lines(abs_path)
  local bufnr = vim.fn.bufnr(abs_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.fn.bufload(bufnr)
    end
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
  end
  if vim.fn.filereadable(abs_path) == 1 then
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

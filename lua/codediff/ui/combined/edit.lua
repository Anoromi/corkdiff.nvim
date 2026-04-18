local M = {}

local model = require("codediff.ui.combined.model")

local function get_or_load_source_buffer(file)
  if file.source_bufnr and vim.api.nvim_buf_is_valid(file.source_bufnr) then
    return file.source_bufnr
  end
  local path = file.source_path
  if not path and file.git_root and file.modified_path then
    path = file.git_root .. "/" .. file.modified_path
  elseif not path and file.git_root and file.path then
    path = file.git_root .. "/" .. file.path
  end
  if not path or path == "" then
    return nil
  end
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  file.source_bufnr = bufnr
  file.source_path = path
  return bufnr
end

local function writable_section_changed(buf_lines, state, section)
  local file = state.files[section.file_index]
  if not file or file.editable then
    return false
  end
  for row, map in pairs(state.line_map or {}) do
    if map.file_index == section.file_index and map.type == "content" then
      local current = buf_lines[row] or ""
      local original = file.modified_lines[map.modified_line] or ""
      if current ~= original then
        return true
      end
    end
  end
  return false
end

local function collect_full_lines(buf_lines, section)
  local start_line = section.header_line + 1
  local end_line = section.end_line or start_line - 1
  local lines = {}
  for row = start_line, end_line do
    local line = buf_lines[row]
    if line and line ~= "(no modified-side lines)" then
      lines[#lines + 1] = line
    end
  end
  return lines
end

local function apply_changes_view_lines(buf_lines, state, section)
  local file = state.files[section.file_index]
  local lines = vim.deepcopy(file.modified_lines or {})
  local rows = {}
  for row, map in pairs(state.line_map or {}) do
    if map.file_index == section.file_index and map.type == "content" then
      rows[#rows + 1] = { row = row, line = map.modified_line }
    end
  end
  table.sort(rows, function(a, b)
    return a.row < b.row
  end)
  for _, item in ipairs(rows) do
    lines[item.line] = buf_lines[item.row] or ""
  end
  return lines
end

local function write_source(file, lines)
  local bufnr = get_or_load_source_buffer(file)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "no writable source buffer for " .. (file.path or "<unknown>")
  end
  if not vim.bo[bufnr].modifiable then
    return false, "source buffer is not modifiable: " .. (file.path or "<unknown>")
  end

  local was_readonly = vim.bo[bufnr].readonly
  vim.bo[bufnr].readonly = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  file.modified_lines = vim.deepcopy(lines)
  file.diff = model.compute_diff(file.original_lines or {}, file.modified_lines or {})

  if vim.bo[bufnr].buftype == "" and vim.api.nvim_buf_get_name(bufnr) ~= "" then
    local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("write")
    end)
    if not ok then
      vim.bo[bufnr].readonly = was_readonly
      return false, tostring(err)
    end
  end
  vim.bo[bufnr].readonly = was_readonly
  return true
end

function M.save(bufnr, state, rebuild)
  if not state then
    return false
  end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local readonly_changed = {}
  local errors = {}

  for _, section in ipairs(state.sections or {}) do
    local file = state.files[section.file_index]
    if file then
      if writable_section_changed(buf_lines, state, section) then
        readonly_changed[#readonly_changed + 1] = file.path or file.old_path or "<unknown>"
      end

      if file.editable then
        local new_lines
        if state.view == "full" then
          new_lines = collect_full_lines(buf_lines, section)
        else
          new_lines = apply_changes_view_lines(buf_lines, state, section)
        end
        local ok, err = write_source(file, new_lines)
        if not ok then
          errors[#errors + 1] = err
        end
      end
    end
  end

  if #readonly_changed > 0 then
    vim.notify("Readonly combined sections were rebuilt: " .. table.concat(readonly_changed, ", "), vim.log.levels.WARN)
  end
  if #errors > 0 then
    vim.notify("Failed to save combined view: " .. table.concat(errors, "; "), vim.log.levels.ERROR)
    return false
  end

  vim.bo[bufnr].modified = false
  if rebuild then
    rebuild()
  end
  return true
end

return M

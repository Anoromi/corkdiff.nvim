local M = {}

local Line = require("codediff.ui.lib.line")
local explorer_nodes = require("codediff.ui.explorer.nodes")

M.ns = vim.api.nvim_create_namespace("codediff-t3code-panel")

local function set_buffer_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
end

local function apply_line_highlights(bufnr, line_entries)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  for line_idx, line in ipairs(line_entries) do
    if line and line._segments then
      local col = 0
      for _, seg in ipairs(line._segments) do
        if seg.hl and seg.hl ~= "" and #seg.text > 0 then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line_idx - 1, col, {
            end_col = col + #seg.text,
            hl_group = seg.hl,
          })
        end
        col = col + #seg.text
      end
    end
  end
end

local function build_turn_line(panel)
  local line = Line()
  local regions = {}
  local col = 1

  for index, turn in ipairs(panel.turn_options or {}) do
    if index > 1 then
      line:append(" ", "CodeDiffT3codeTabSeparator")
      col = col + 1
    end

    local label = " " .. turn.label .. " "
    local hl = panel.selected_turn == turn.value and "CodeDiffT3codeTabActive" or "CodeDiffT3codeTabInactive"
    line:append(label, hl)
    regions[#regions + 1] = {
      start_col = col,
      end_col = col + #label - 1,
      turn = turn.value,
    }
    col = col + #label
  end

  return line, regions
end

local function build_file_line(panel, entry, width)
  return explorer_nodes.prepare_flat_file_line(entry, width, {
    selected = panel.current_file_key == entry.key,
    selection_hl = "CodeDiffT3codeSelection",
    filename_hl = "CodeDiffT3codeFilename",
    path_hl = "CodeDiffT3codePath",
    normal_hl = "Normal",
  })
end

function M.render(panel)
  local width = 40
  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    width = vim.api.nvim_win_get_width(panel.winid)
  end

  local line_entries = {}
  local plain_lines = {}
  local file_rows = {}

  local function push(line, file_entry)
    line_entries[#line_entries + 1] = line
    plain_lines[#plain_lines + 1] = line and line:content() or ""
    if file_entry then
      file_rows[#plain_lines] = file_entry
    end
  end

  local title = Line()
  title:append(panel.thread.title or "T3code", "CodeDiffT3codeHeading")
  push(title)

  local mode = Line()
  mode:append(panel.turn_view_mode == "live" and "Live" or "History", "CodeDiffT3codeTabInactive")
  push(mode)

  local turns_line, regions = build_turn_line(panel)
  push(turns_line)
  push(Line())

  local files_heading = Line()
  files_heading:append(string.format("Files (%d)", #(panel.files or {})), "CodeDiffT3codeHeading")
  push(files_heading)

  local content_width = math.max(width - 1, 20)
  if #(panel.files or {}) == 0 then
    local empty = Line()
    empty:append("No changed files", "CodeDiffT3codePath")
    push(empty)
  else
    for _, entry in ipairs(panel.files or {}) do
      push(build_file_line(panel, entry, content_width), entry)
    end
  end

  panel.turn_regions = regions
  panel.turn_line = 3
  panel.file_rows = file_rows

  set_buffer_lines(panel.bufnr, plain_lines)
  apply_line_highlights(panel.bufnr, line_entries)
end

return M

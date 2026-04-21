local M = {}

local config = require("codediff.config")
local inline = require("codediff.ui.inline")

M.ns = vim.api.nvim_create_namespace("codediff-combined")
M.ns_diag = vim.api.nvim_create_namespace("codediff-combined-diagnostics")

local OMITTED = "... unchanged lines omitted ..."

local function combined_config()
  return ((config.options.diff or {}).combined or {})
end

local function profile(label, started)
  if not vim.g.codediff_combined_profile then
    return
  end
  local elapsed = (vim.uv.hrtime() - started) / 1000000
  vim.schedule(function()
    vim.notify(string.format("[codediff:combined] %s %.1fms", label, elapsed), vim.log.levels.DEBUG)
  end)
end

local function line_count(lines)
  return #(lines or {})
end

local function is_changed_modified_line(diff, line)
  for _, change in ipairs((diff and diff.changes) or {}) do
    if line >= change.modified.start_line and line < change.modified.end_line then
      return true
    end
  end
  return false
end

local function range_len(range)
  return math.max(0, (range.end_line or 0) - (range.start_line or 0))
end

local function merge_ranges(ranges)
  table.sort(ranges, function(a, b)
    if a.start == b.start then
      return a.finish < b.finish
    end
    return a.start < b.start
  end)
  local merged = {}
  for _, range in ipairs(ranges) do
    if range.finish > range.start then
      local last = merged[#merged]
      if last and range.start <= last.finish then
        last.finish = math.max(last.finish, range.finish)
      else
        merged[#merged + 1] = { start = range.start, finish = range.finish }
      end
    end
  end
  return merged
end

local function build_full_ranges(file)
  local modified_count = line_count(file.modified_lines)
  if modified_count > 0 then
    return { { start = 1, finish = modified_count + 1 } }
  end
  return {}
end

local function build_modified_ranges(file, change)
  local modified_count = line_count(file.modified_lines)
  local context = tonumber(combined_config().context_lines) or 3
  if modified_count == 0 or range_len(change.modified) == 0 then
    return {}
  end

  return merge_ranges({
    {
      start = math.max(1, change.modified.start_line - context),
      finish = math.min(modified_count + 1, change.modified.end_line + context),
    },
  })
end

local function build_hunk_blocks(file, view)
  if view == "full" then
    return {
      {
        type = "full",
        modified_ranges = build_full_ranges(file),
        original_ranges = {},
      },
    }
  end

  local blocks = {}
  for _, change in ipairs((file.diff and file.diff.changes) or {}) do
    blocks[#blocks + 1] = {
      type = "hunk",
      change = change,
      modified_ranges = build_modified_ranges(file, change),
      original_ranges = range_len(change.original) > 0
          and { { start = change.original.start_line, finish = change.original.end_line } }
        or {},
    }
  end
  return blocks
end

local function header_for(file)
  local parts = {
    "@@",
    file.path or file.old_path or "<unknown>",
    file.status or "M",
    file.group or "",
  }
  if file.readonly_reason then
    parts[#parts + 1] = "(" .. file.readonly_reason .. ")"
  end
  parts[#parts + 1] = "@@"
  return table.concat(parts, " ")
end

local function find_anchor_row(state, file_index, mod_line, fallback, change)
  local best_after = nil
  local best_before = nil
  local best_deleted = nil
  for row, map in pairs(state.line_map) do
    if map.file_index == file_index then
      if map.type == "content" and map.modified_line then
        if map.modified_line >= mod_line then
          if not best_after or row < best_after then
            best_after = row
          end
        elseif not best_before or row > best_before then
          best_before = row
        end
      elseif map.type == "deleted_content" and (not change or map.change == change) then
        if not best_deleted or row < best_deleted then
          best_deleted = row
        end
      end
    end
  end
  if change and range_len(change.modified) == 0 and best_deleted then
    return best_deleted
  end
  return best_after or best_before or best_deleted or fallback
end

local function deleted_virt_lines(file, change)
  local virt_lines = {}
  for line = change.original.start_line, change.original.end_line - 1 do
    virt_lines[#virt_lines + 1] = {
      { file.original_lines[line] or "", "CodeDiffLineDelete" },
      { string.rep(" ", 300), "CodeDiffLineDelete" },
    }
  end
  return virt_lines
end

function M.render(bufnr, files, opts)
  opts = opts or {}
  local render_started = vim.uv.hrtime()
  local view = opts.view or combined_config().initial_view or "changes"
  if view ~= "full" then
    view = "changes"
  end

  local state = {
    view = view,
    files = files or {},
    sections = {},
    line_map = {},
    hunks = {},
    previous_layout = opts.previous_layout,
  }

  local lines = {}
  local syntax_by_file = {}
  local original_syntax_by_file = {}
  local function add_line(text, map)
    lines[#lines + 1] = text
    state.line_map[#lines] = map or { type = "structural" }
    return #lines
  end

  for file_index, file in ipairs(files or {}) do
    if file.syntax_hls then
      syntax_by_file[file_index] = file.syntax_hls
    else
      local syntax_started = vim.uv.hrtime()
      file.syntax_hls = inline.compute_syntax_highlights(file.modified_lines or {}, file.filetype)
      profile("syntax " .. tostring(file.path or file.old_path or file_index), syntax_started)
      syntax_by_file[file_index] = file.syntax_hls
    end
    if file.original_syntax_hls then
      original_syntax_by_file[file_index] = file.original_syntax_hls
    else
      local syntax_started = vim.uv.hrtime()
      file.original_syntax_hls = inline.compute_syntax_highlights(file.original_lines or {}, file.filetype)
      profile("original syntax " .. tostring(file.path or file.old_path or file_index), syntax_started)
      original_syntax_by_file[file_index] = file.original_syntax_hls
    end
    if #lines > 0 then
      add_line("", { type = "separator", file_index = file_index })
    end

    local section = {
      file_index = file_index,
      path = file.path,
      old_path = file.old_path,
      start_line = #lines + 1,
      header_line = #lines + 1,
      header_text = header_for(file),
      ranges = {},
    }
    state.sections[#state.sections + 1] = section
    add_line(section.header_text, { type = "header", file_index = file_index })

    if file.load_error then
      add_line("Failed to load modified content: " .. tostring(file.load_error), {
        type = "error",
        file_index = file_index,
      })
    else
      local blocks = build_hunk_blocks(file, view)
      section.blocks = blocks
      if #blocks == 0 or (#blocks == 1 and blocks[1].type == "full" and #blocks[1].modified_ranges == 0) then
        if line_count(file.original_lines) > 0 and line_count(file.modified_lines) == 0 then
          for line = 1, line_count(file.original_lines) do
            add_line(file.original_lines[line] or "", {
              type = "deleted_content",
              file_index = file_index,
              original_line = line,
            })
          end
        else
          add_line("(empty file)", { type = "structural", file_index = file_index })
        end
      end

      local last_finish = 1
      for _, block in ipairs(blocks) do
        if block.type == "hunk" and #block.modified_ranges == 0 and #block.original_ranges > 0 then
          local span_start = #lines + 1
          for _, range in ipairs(block.original_ranges) do
            for line = range.start, range.finish - 1 do
              add_line(file.original_lines[line] or "", {
                type = "deleted_content",
                file_index = file_index,
                original_line = line,
                change = block.change,
              })
            end
          end
          local span_finish = #lines
          section.spans = section.spans or {}
          section.spans[#section.spans + 1] = {
            start_line = span_start,
            end_line = span_finish,
            original_start = block.original_ranges[1].start,
            original_end = block.original_ranges[#block.original_ranges].finish,
          }
        else
          for _, range in ipairs(block.modified_ranges or {}) do
            if view == "changes" and range.start > last_finish then
              add_line(OMITTED, { type = "omitted", file_index = file_index })
            end
            local start_line = range.start
            if view == "changes" and start_line < last_finish then
              start_line = last_finish
            end
            if start_line >= range.finish then
              last_finish = math.max(last_finish, range.finish)
            else
              local span_start = #lines + 1
              for line = start_line, range.finish - 1 do
                add_line(file.modified_lines[line] or "", {
                  type = "content",
                  file_index = file_index,
                  path = file.path,
                  source_path = file.source_path,
                  source_bufnr = file.source_bufnr,
                  modified_line = line,
                  editable = file.editable,
                  change = block.change,
                })
              end
              local span_finish = #lines
              section.spans = section.spans or {}
              section.spans[#section.spans + 1] = {
                start_line = span_start,
                end_line = span_finish,
                modified_start = start_line,
                modified_end = range.finish,
              }
              last_finish = range.finish
            end
          end
        end
      end
      if view == "changes" and last_finish <= line_count(file.modified_lines) and #blocks > 0 then
        add_line(OMITTED, { type = "omitted", file_index = file_index })
      end
    end
    section.end_line = #lines
  end

  if #lines == 0 then
    add_line("No changes to show", { type = "structural" })
  end

  local was_modifiable = vim.bo[bufnr].modifiable
  local was_readonly = vim.bo[bufnr].readonly
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_diag, 0, -1)

  local priority = config.options.diff.highlight_priority or 100
  for row, map in pairs(state.line_map) do
    local row0 = row - 1
    if map.type == "header" then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row0, 0, {
        end_line = row0 + 1,
        end_col = 0,
        hl_group = "Title",
        hl_eol = true,
        priority = priority,
      })
    elseif map.type == "omitted" or map.type == "separator" or map.type == "structural" then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row0, 0, {
        end_line = row0 + 1,
        end_col = 0,
        hl_group = "Comment",
        hl_eol = false,
        priority = priority,
      })
    elseif map.type == "error" then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row0, 0, {
        end_line = row0 + 1,
        end_col = 0,
        hl_group = "DiagnosticWarn",
        hl_eol = true,
        priority = priority,
      })
    elseif map.type == "content" then
      local file = state.files[map.file_index]
      if file and is_changed_modified_line(file.diff, map.modified_line) then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row0, 0, {
          end_line = row0 + 1,
          end_col = 0,
          hl_group = "CodeDiffLineInsert",
          hl_eol = true,
          priority = priority,
        })
      end
      for _, syntax_hl in ipairs((syntax_by_file[map.file_index] or {})[map.modified_line] or {}) do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row0, math.max((syntax_hl.start_col or 1) - 1, 0), {
          end_col = syntax_hl.end_col,
          hl_group = syntax_hl.hl_group,
          hl_mode = "combine",
          priority = priority + 1,
        })
      end
    elseif map.type == "deleted_content" then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row0, 0, {
        end_line = row0 + 1,
        end_col = 0,
        hl_group = "CodeDiffLineDelete",
        hl_eol = true,
        priority = priority,
      })
      for _, syntax_hl in ipairs((original_syntax_by_file[map.file_index] or {})[map.original_line] or {}) do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row0, math.max((syntax_hl.start_col or 1) - 1, 0), {
          end_col = syntax_hl.end_col,
          hl_group = syntax_hl.hl_group,
          hl_mode = "combine",
          priority = priority + 1,
        })
      end
    end
  end

  for file_index, file in ipairs(files or {}) do
    local section = state.sections[file_index]
    for _, change in ipairs((file.diff and file.diff.changes) or {}) do
      local anchor = find_anchor_row(state, file_index, change.modified.start_line, section and section.header_line or 1, change)
      state.hunks[#state.hunks + 1] = {
        file_index = file_index,
        path = file.path,
        line = anchor,
        change = change,
      }

      if range_len(change.modified) > 0 and change.original.end_line > change.original.start_line then
        local virt_lines = deleted_virt_lines(file, change)
        if #virt_lines > 0 then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, math.max(anchor - 1, 0), 0, {
            virt_lines = virt_lines,
            virt_lines_above = true,
            priority = priority,
          })
        end
      end
    end
  end

  table.sort(state.hunks, function(a, b)
    return a.line < b.line
  end)

  vim.bo[bufnr].modifiable = was_modifiable
  vim.bo[bufnr].readonly = was_readonly
  vim.bo[bufnr].modified = false
  profile("render", render_started)
  return state
end

function M.mirror_diagnostics(bufnr, state)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not state then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_diag, 0, -1)
  local rows_by_source = {}
  for row, map in pairs(state.line_map or {}) do
    if map.type == "content" and map.source_bufnr and vim.api.nvim_buf_is_valid(map.source_bufnr) then
      local lnum = map.modified_line - 1
      rows_by_source[map.source_bufnr] = rows_by_source[map.source_bufnr] or {}
      rows_by_source[map.source_bufnr][lnum] = rows_by_source[map.source_bufnr][lnum] or {}
      rows_by_source[map.source_bufnr][lnum][#rows_by_source[map.source_bufnr][lnum] + 1] = row
    end
  end

  for source_bufnr, rows_by_lnum in pairs(rows_by_source) do
    local diagnostics = vim.diagnostic.get(source_bufnr)
    for _, diagnostic in ipairs(diagnostics) do
      local rows = rows_by_lnum[diagnostic.lnum]
      if rows then
        for _, row in ipairs(rows) do
          local hl = "DiagnosticUnderlineInfo"
          if diagnostic.severity == vim.diagnostic.severity.ERROR then
            hl = "DiagnosticUnderlineError"
          elseif diagnostic.severity == vim.diagnostic.severity.WARN then
            hl = "DiagnosticUnderlineWarn"
          elseif diagnostic.severity == vim.diagnostic.severity.HINT then
            hl = "DiagnosticUnderlineHint"
          end
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_diag, row - 1, diagnostic.col or 0, {
            end_col = diagnostic.end_col,
            hl_group = hl,
            virt_text = { { diagnostic.message or "", "DiagnosticVirtualTextInfo" } },
            virt_text_pos = "eol",
          })
        end
      end
    end
  end
end
return M

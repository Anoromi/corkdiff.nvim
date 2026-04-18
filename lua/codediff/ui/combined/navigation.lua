local M = {}

local lifecycle = require("codediff.ui.lifecycle")

local function current_state(tabpage)
  local session = lifecycle.get_session(tabpage or vim.api.nvim_get_current_tabpage())
  return session, session and session.combined
end

local function goto_line(line)
  if line and line > 0 then
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    vim.cmd("normal! zz")
    return true
  end
  return false
end

function M.line_map_at_cursor(tabpage)
  local _, state = current_state(tabpage)
  if not state then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_map and state.line_map[row] or nil
end

function M.current_file(tabpage)
  local _, state = current_state(tabpage)
  local map = M.line_map_at_cursor(tabpage)
  if not state or not map or not map.file_index then
    return nil
  end
  return state.files[map.file_index], map
end

function M.next_hunk(tabpage)
  local _, state = current_state(tabpage)
  if not state or not state.hunks or #state.hunks == 0 then
    return false
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for index, hunk in ipairs(state.hunks) do
    if hunk.line > line then
      vim.api.nvim_echo({ { string.format("Hunk %d of %d", index, #state.hunks), "None" } }, false, {})
      return goto_line(hunk.line)
    end
  end
  if require("codediff.config").options.diff.cycle_next_hunk then
    vim.api.nvim_echo({ { string.format("Hunk 1 of %d", #state.hunks), "None" } }, false, {})
    return goto_line(state.hunks[1].line)
  end
  vim.api.nvim_echo({ { string.format("Last hunk (%d of %d)", #state.hunks, #state.hunks), "WarningMsg" } }, false, {})
  return false
end

function M.prev_hunk(tabpage)
  local _, state = current_state(tabpage)
  if not state or not state.hunks or #state.hunks == 0 then
    return false
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for index = #state.hunks, 1, -1 do
    local hunk = state.hunks[index]
    if hunk.line < line then
      vim.api.nvim_echo({ { string.format("Hunk %d of %d", index, #state.hunks), "None" } }, false, {})
      return goto_line(hunk.line)
    end
  end
  if require("codediff.config").options.diff.cycle_next_hunk then
    vim.api.nvim_echo({ { string.format("Hunk %d of %d", #state.hunks, #state.hunks), "None" } }, false, {})
    return goto_line(state.hunks[#state.hunks].line)
  end
  vim.api.nvim_echo({ { string.format("First hunk (1 of %d)", #state.hunks), "WarningMsg" } }, false, {})
  return false
end

local function sync_panel_selection(tabpage, file)
  local session = lifecycle.get_session(tabpage)
  local panel = lifecycle.get_explorer(tabpage)
  if not session or not panel or not file then
    return
  end
  if session.mode == "t3code" then
    panel.current_file_key = file.key
    local state = session.t3code
    if state then
      state.current_file_key = file.key
      for _, entry in ipairs(state.files or {}) do
        if entry.key == file.key then
          state.current_file = vim.deepcopy(entry)
          break
        end
      end
    end
    pcall(require("codediff.t3code.panel").render, panel)
    return
  end

  panel.current_file_path = file.path
  panel.current_file_group = file.group
  panel.current_selection = {
    path = file.path,
    old_path = file.old_path,
    status = file.status,
    git_root = file.git_root,
    group = file.group,
  }
  if panel.tree then
    panel.tree:render()
  end
end

function M.jump_to_file(tabpage, file_data)
  local _, state = current_state(tabpage)
  if not state then
    return false
  end
  local target_index = nil
  for index, file in ipairs(state.files or {}) do
    if file.path == file_data.path and (not file_data.group or file.group == file_data.group) then
      target_index = index
      break
    end
  end
  if not target_index then
    return false
  end
  for _, section in ipairs(state.sections or {}) do
    if section.file_index == target_index then
      sync_panel_selection(tabpage, state.files[target_index])
      return goto_line(section.header_line)
    end
  end
  return false
end

function M.next_file(tabpage)
  local _, state = current_state(tabpage)
  if not state or not state.sections or #state.sections == 0 then
    return false
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for _, section in ipairs(state.sections) do
    if section.header_line > line then
      sync_panel_selection(tabpage or vim.api.nvim_get_current_tabpage(), state.files[section.file_index])
      return goto_line(section.header_line)
    end
  end
  local first = state.sections[1]
  sync_panel_selection(tabpage or vim.api.nvim_get_current_tabpage(), state.files[first.file_index])
  return goto_line(first.header_line)
end

function M.prev_file(tabpage)
  local _, state = current_state(tabpage)
  if not state or not state.sections or #state.sections == 0 then
    return false
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for index = #state.sections, 1, -1 do
    local section = state.sections[index]
    if section.header_line < line then
      sync_panel_selection(tabpage or vim.api.nvim_get_current_tabpage(), state.files[section.file_index])
      return goto_line(section.header_line)
    end
  end
  local last = state.sections[#state.sections]
  sync_panel_selection(tabpage or vim.api.nvim_get_current_tabpage(), state.files[last.file_index])
  return goto_line(last.header_line)
end

return M

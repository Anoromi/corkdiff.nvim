local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local layout = require("codediff.ui.layout")
local panel = require("codediff.ui.view.panel")
local events = require("codediff.ui.events")

local cache = require("codediff.ui.combined.cache")
local render = require("codediff.ui.combined.render")
local edit = require("codediff.ui.combined.edit")

local set_t3code_current_file

local function combined_config()
  return ((config.options.diff or {}).combined or {})
end

local function default_previous_layout()
  local configured = (config.options.diff or {}).layout
  if configured == "side-by-side" or configured == "inline" then
    return configured
  end
  return "inline"
end

local function setup_keymaps(tabpage, original_bufnr, combined_bufnr)
  local session = lifecycle.get_session(tabpage)
  require("codediff.ui.view.keymaps").setup_all_keymaps(tabpage, original_bufnr, combined_bufnr, session and session.mode == "explorer")
end

local function make_combined_buffer(tabpage)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "codediff-combined"
  pcall(vim.api.nvim_buf_set_name, bufnr, "CodeDiff " .. tabpage .. ".combined")
  return bufnr
end

local function install_autocmds(tabpage, bufnr)
  local group = vim.api.nvim_create_augroup("CodeDiffCombined_" .. tabpage, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      local session = lifecycle.get_session(tabpage)
      if not session or not session.combined then
        return
      end
      edit.save(bufnr, session.combined, function()
        cache.invalidate(tabpage, "combined-save")
        M.rerender(tabpage, { preserve_cursor = true })
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      local navigation = require("codediff.ui.combined.navigation")
      local file = navigation.current_file(tabpage)
      local panel_obj = lifecycle.get_explorer(tabpage)
      local session = lifecycle.get_session(tabpage)
      if not file or not panel_obj or not session then
        return
      end
      if session.mode == "t3code" then
        if panel_obj.current_file_key == file.key then
          return
        end
        set_t3code_current_file(tabpage, file)
        pcall(require("codediff.t3code.panel").render, panel_obj)
      elseif panel_obj.current_file_path ~= file.path or panel_obj.current_file_group ~= file.group then
        panel_obj.current_file_path = file.path
        panel_obj.current_file_group = file.group
        panel_obj.current_selection = {
          path = file.path,
          old_path = file.old_path,
          status = file.status,
          git_root = file.git_root,
          group = file.group,
        }
        if panel_obj.tree then
          panel_obj.tree:render()
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function()
      local session = lifecycle.get_session(tabpage)
      if session and session.combined then
        if session.combined_diagnostic_timer then
          vim.fn.timer_stop(session.combined_diagnostic_timer)
        end
        session.combined_diagnostic_timer = vim.fn.timer_start(100, function()
          session.combined_diagnostic_timer = nil
          local current = lifecycle.get_session(tabpage)
          if current and current.combined then
            render.mirror_diagnostics(bufnr, current.combined)
          end
        end)
      end
    end,
  })
end

local function get_or_create_combined_window(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return nil
  end

  local keep_win = (session.modified_win and vim.api.nvim_win_is_valid(session.modified_win) and session.modified_win)
    or (session.original_win and vim.api.nvim_win_is_valid(session.original_win) and session.original_win)
  if not keep_win then
    return nil
  end

  local close_win = nil
  if session.original_win and session.modified_win and session.original_win ~= session.modified_win then
    close_win = session.original_win == keep_win and session.modified_win or session.original_win
  end
  if close_win and vim.api.nvim_win_is_valid(close_win) then
    vim.api.nvim_set_current_win(keep_win)
    pcall(vim.api.nvim_win_close, close_win, true)
  end

  session.original_win = keep_win
  session.modified_win = keep_win
  session.single_pane = nil
  return keep_win
end

local function render_loading(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.modified_bufnr or not vim.api.nvim_buf_is_valid(session.modified_bufnr) then
    return
  end
  local bufnr = session.modified_bufnr
  local was_modifiable = vim.bo[bufnr].modifiable
  local was_readonly = vim.bo[bufnr].readonly
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Building combined view..." })
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = was_modifiable
  vim.bo[bufnr].readonly = was_readonly
end

local function current_panel_file(tabpage)
  local session = lifecycle.get_session(tabpage)
  local panel_obj = lifecycle.get_explorer(tabpage)
  if not session or not panel_obj then
    return nil
  end

  if session.mode == "t3code" then
    local state = session.t3code
    local key = panel_obj.current_file_key or (state and state.current_file_key)
    if key and state then
      for _, file in ipairs(state.files or {}) do
        if file.key == key then
          return file
        end
      end
    end
    return state and state.current_file or nil
  end

  return panel_obj.current_selection
end

set_t3code_current_file = function(tabpage, file)
  local session = lifecycle.get_session(tabpage)
  local panel_obj = lifecycle.get_explorer(tabpage)
  if not session or not session.t3code or not panel_obj or not file then
    return false
  end

  panel_obj.current_file_key = file.key
  session.t3code.current_file_key = file.key
  for _, entry in ipairs(session.t3code.files or {}) do
    if entry.key == file.key then
      session.t3code.current_file = vim.deepcopy(entry)
      return true
    end
  end
  session.t3code.current_file = vim.deepcopy(file)
  return true
end

local function sync_combined_cursor_file(tabpage)
  local session = lifecycle.get_session(tabpage)
  local panel_obj = lifecycle.get_explorer(tabpage)
  if not session or not panel_obj or session.layout ~= "combined" then
    return nil
  end

  local file = require("codediff.ui.combined.navigation").current_file(tabpage)
  if not file then
    return nil
  end

  if session.mode == "t3code" then
    set_t3code_current_file(tabpage, file)
    return file
  end

  panel_obj.current_file_path = file.path
  panel_obj.current_file_group = file.group
  panel_obj.current_selection = {
    path = file.path,
    old_path = file.old_path,
    status = file.status,
    git_root = file.git_root,
    group = file.group,
  }
  return file
end

local function apply_render(tabpage, files, opts)
  opts = opts or {}
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end
  local combined_bufnr = session.modified_bufnr
  if not combined_bufnr or not vim.api.nvim_buf_is_valid(combined_bufnr) then
    return false
  end

  local old_cursor = nil
  if opts.preserve_cursor and session.modified_win and vim.api.nvim_win_is_valid(session.modified_win) then
    old_cursor = vim.api.nvim_win_get_cursor(session.modified_win)
  end

  local view = opts.view or (session.combined and session.combined.view) or combined_config().initial_view or "changes"
  local render_signature = table.concat({ cache.get_signature(tabpage) or "", view }, "::")
  local state = render.render(combined_bufnr, files, {
    view = view,
    previous_layout = session.combined_previous_layout or (session.combined and session.combined.previous_layout),
  })
  state.render_signature = render_signature
  session.combined = state
  session.stored_diff_result = {
    changes = vim.tbl_map(function(hunk)
      return hunk.change
    end, state.hunks or {}),
    moves = {},
  }
  render.mirror_diagnostics(combined_bufnr, state)

  if old_cursor and session.modified_win and vim.api.nvim_win_is_valid(session.modified_win) then
    local line_count = vim.api.nvim_buf_line_count(combined_bufnr)
    pcall(vim.api.nvim_win_set_cursor, session.modified_win, { math.min(old_cursor[1], line_count), old_cursor[2] })
  elseif session.modified_win and vim.api.nvim_win_is_valid(session.modified_win) and state.hunks and state.hunks[1] then
    pcall(vim.api.nvim_win_set_cursor, session.modified_win, { state.hunks[1].line, 0 })
  end

  return true
end

function M.rerender(tabpage, opts)
  opts = opts or {}
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end
  if session.modified_bufnr and vim.api.nvim_buf_is_valid(session.modified_bufnr) and vim.bo[session.modified_bufnr].modified then
    if not session.combined_dirty_notified then
      vim.notify("Combined view has unsaved edits; write it before refreshing", vim.log.levels.WARN)
      session.combined_dirty_notified = true
    end
    return false
  end
  if not cache.get_ready_files(tabpage) then
    render_loading(tabpage)
  end
  cache.get_or_build(tabpage, function(err, files)
    vim.schedule(function()
      if err then
        vim.notify("Failed to build combined view: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      session.combined_dirty_notified = false
      local view = opts.view or (session.combined and session.combined.view) or combined_config().initial_view or "changes"
      local render_signature = table.concat({ cache.get_signature(tabpage) or "", view }, "::")
      if
        not opts.force_render
        and not opts.focus_file
        and session.combined
        and session.combined.render_signature == render_signature
        and session.modified_bufnr
        and vim.api.nvim_buf_is_valid(session.modified_bufnr)
        and not vim.bo[session.modified_bufnr].modified
      then
        layout.arrange(tabpage)
        return
      end
      local rendered = apply_render(tabpage, files or {}, opts)
      if rendered and opts.focus_file then
        require("codediff.ui.combined.navigation").jump_to_file(tabpage, opts.focus_file)
      end
      layout.arrange(tabpage)
    end)
  end)
  return true
end

function M.create(session_config, _filetype, on_ready)
  if not session_config.reuse_current_tab then
    vim.cmd("tabnew")
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local win = vim.api.nvim_get_current_win()
  local initial_buf = vim.api.nvim_get_current_buf()
  local combined_buf = make_combined_buffer(tabpage)
  local original_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[original_buf].buftype = "nofile"
  vim.api.nvim_win_set_buf(win, combined_buf)

  if vim.api.nvim_buf_is_valid(initial_buf) and initial_buf ~= combined_buf then
    pcall(vim.api.nvim_buf_delete, initial_buf, { force = true })
  end

  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  lifecycle.create_session(
    tabpage,
    session_config.mode,
    session_config.git_root,
    "",
    "",
    nil,
    nil,
    original_buf,
    combined_buf,
    win,
    win,
    { changes = {}, moves = {} },
    function()
      setup_keymaps(tabpage, original_buf, combined_buf)
    end
  )

  local session = lifecycle.get_session(tabpage)
	session.combined_previous_layout = session_config.previous_layout or default_previous_layout()
  lifecycle.update_layout(tabpage, "combined")

  panel.setup_explorer(tabpage, session_config, win, win)
  panel.setup_t3code(tabpage, session_config)
  setup_keymaps(tabpage, original_buf, combined_buf)
  install_autocmds(tabpage, combined_buf)
  cache.precompute(tabpage, { immediate = true, force = true })
  M.rerender(tabpage, {
    view = combined_config().initial_view or "changes",
    focus_file = current_panel_file(tabpage),
  })
  layout.arrange(tabpage)
  events.emit("CodeDiffOpen", { tabpage = tabpage, mode = session_config.mode, layout = "combined" })
  if on_ready then
    vim.schedule(on_ready)
  end

  return { original_buf = original_buf, modified_buf = combined_buf, original_win = win, modified_win = win }
end

function M.enter(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end
  if session.mode ~= "explorer" and session.mode ~= "t3code" then
    vim.notify("Combined view only supports explorer and t3code sessions", vim.log.levels.WARN)
    return false
  end
  if session.layout == "combined" then
    return true
  end

  local previous_layout = session.layout == "combined" and "inline" or (session.layout or "inline")
  local win = get_or_create_combined_window(tabpage)
  if not win then
    return false
  end

  local old_orig = session.original_bufnr
  local old_mod = session.modified_bufnr
  if old_orig and vim.api.nvim_buf_is_valid(old_orig) then
    require("codediff.ui.auto_refresh").disable(old_orig)
  end
  if old_mod and vim.api.nvim_buf_is_valid(old_mod) then
    require("codediff.ui.auto_refresh").disable(old_mod)
  end

  local combined_buf = make_combined_buffer(tabpage)
  local original_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[original_buf].buftype = "nofile"
  vim.api.nvim_win_set_buf(win, combined_buf)
  session.combined_previous_layout = previous_layout
  lifecycle.update_buffers(tabpage, original_buf, combined_buf)
  lifecycle.update_paths(tabpage, "", "")
  lifecycle.update_revisions(tabpage, nil, nil)
  lifecycle.update_layout(tabpage, "combined")
  install_autocmds(tabpage, combined_buf)
  setup_keymaps(tabpage, original_buf, combined_buf)
  cache.precompute(tabpage, { immediate = true, force = true })
  M.rerender(tabpage, {
    view = combined_config().initial_view or "changes",
    focus_file = current_panel_file(tabpage),
  })
  layout.arrange(tabpage)
  return true
end

function M.leave(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or session.layout ~= "combined" then
    return false
  end
  if session.modified_bufnr and vim.api.nvim_buf_is_valid(session.modified_bufnr) and vim.bo[session.modified_bufnr].modified then
    vim.notify("Write or abandon combined edits before leaving combined view", vim.log.levels.WARN)
    return false
  end

  local focused_file = sync_combined_cursor_file(tabpage)
  local target = session.combined_previous_layout or (session.combined and session.combined.previous_layout) or "inline"
  if target ~= "side-by-side" then
    target = "inline"
  end
  lifecycle.update_layout(tabpage, target)
  session.combined = nil
  session.single_pane = target == "side-by-side" and true or nil
  if target == "side-by-side" then
    session.original_win = nil
  end

  local panel_obj = lifecycle.get_explorer(tabpage)
  if session.mode == "t3code" then
    if focused_file and session.t3code and not session.t3code.current_file then
      session.t3code.current_file = vim.deepcopy(focused_file)
      session.t3code.current_file_key = focused_file.key
    end
    return require("codediff.t3code.session").rerender_current(panel_obj)
  end
  return require("codediff.ui.explorer").rerender_current(panel_obj)
end

function M.toggle(tabpage)
  local session = lifecycle.get_session(tabpage or vim.api.nvim_get_current_tabpage())
  if session and session.layout == "combined" then
    return M.leave(tabpage)
  end
  return M.enter(tabpage)
end

function M.toggle_view(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session or session.layout ~= "combined" or not session.combined then
    vim.notify("Combined view is not active", vim.log.levels.WARN)
    return false
  end
  local next_view = session.combined.view == "full" and "changes" or "full"
  if session.modified_bufnr and vim.api.nvim_buf_is_valid(session.modified_bufnr) and vim.bo[session.modified_bufnr].modified then
    vim.notify("Write combined edits before switching view mode", vim.log.levels.WARN)
    return false
  end
  return apply_render(tabpage, session.combined.files or {}, { view = next_view, preserve_cursor = true })
end

function M.update(tabpage, _session_config, _auto_scroll_to_first_hunk)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end
  if session.layout ~= "combined" then
    return M.enter(tabpage)
  end
  return M.rerender(tabpage, { preserve_cursor = true })
end

return M

local M = {}

local config = require("codediff.config")
local lifecycle = require("codediff.ui.lifecycle")
local layout = require("codediff.ui.layout")
local snapshot = require("codediff.t3code.snapshot")
local projector = require("codediff.t3code.projector")
local panel_ui = require("codediff.t3code.panel")
local transport = require("codediff.t3code.transport")
local desktop = require("codediff.t3code.desktop")

local function notify_err(err)
  vim.notify("[corkdiff:t3code] " .. err, vim.log.levels.ERROR)
end

local function build_thread_label(thread)
  local branch = thread.branch or "no-branch"
  local repo = thread.worktreePath or (thread.project and thread.project.workspaceRoot) or "no-worktree"
  local updated = thread.updatedAt or ""
  return string.format("%s | %s | %s | %s", thread.title, branch, repo, updated)
end

local function build_turn_options(thread)
  local options = {
    { label = "All", value = "all" },
  }
  local checkpoints = vim.deepcopy(thread.checkpoints or {})
  table.sort(checkpoints, function(left, right)
    return (left.turnCount or 0) > (right.turnCount or 0)
  end)
  for _, checkpoint in ipairs(checkpoints) do
    table.insert(options, {
      label = tostring(checkpoint.turnCount),
      value = checkpoint.turnCount,
    })
  end
  return options
end

local REFRESHABLE_EVENT_TYPES = {
  ["thread.turn-diff-completed"] = true,
  ["thread.reverted"] = true,
  ["thread.meta-updated"] = true,
  ["thread.archived"] = true,
  ["thread.unarchived"] = true,
  ["thread.deleted"] = true,
}

local perform_refresh
local start_event_stream
local stop_event_stream
local schedule_reconnect
local cancel_reconnect

local function t3code_config()
  return config.options.t3code or {}
end

local function auto_refresh_enabled()
  return t3code_config().auto_refresh ~= false
end

local function refresh_debounce_ms()
  return t3code_config().refresh_debounce_ms or 250
end

local function reconnect_delay_ms()
  return t3code_config().reconnect_delay_ms or 1000
end

local function stop_timer(timer_id)
  if timer_id then
    vim.fn.timer_stop(timer_id)
  end
  return nil
end

local function notify_stream_debug(message, level)
  vim.schedule(function()
    vim.notify("[corkdiff:t3code] " .. message, level or vim.log.levels.INFO)
  end)
end

-- Jibberish marker: plum rocket cardigan meadow.
-- Jibberish marker: saffron axle paperclip raindrop.
-- Jibberish marker: walnut hinge confetti lantern.

local function session_state(tabpage)
  local session = lifecycle.get_session(tabpage)
  return session and session.t3code or nil
end

local function sync_panel(panel, state)
  panel.thread = state.thread
  panel.turn_options = state.turn_options
  panel.selected_turn = state.selected_turn
  panel.turn_view_mode = state.turn_view_mode
  panel.files = state.files
  panel.current_file_key = state.current_file_key
  panel_ui.render(panel)
end

local function list_files_for_state(state)
  local files, err = projector.list_files(
    state.thread,
    state.selected_turn,
    state.transport,
    state.diff_cache
  )
  if not files then
    return nil, err
  end

  local mapped = {}
  for _, entry in ipairs(files) do
    local key = table.concat({ entry.status, entry.old_path or "", entry.path }, "::")
    mapped[#mapped + 1] = {
      key = key,
      path = entry.path,
      old_path = entry.old_path,
      status = entry.status,
    }
  end

  table.sort(mapped, function(left, right)
    return left.path < right.path
  end)
  return mapped, nil
end

local function apply_current_selection(tabpage, auto_scroll)
  local state = session_state(tabpage)
  if not state or not state.current_file then
    return false
  end

  local view = require("codediff.ui.view")
  local session_config
  local err
  if state.turn_view_mode == "history" then
    session_config, err = projector.build_history_view(state.thread, state.current_file, state.selected_turn)
  else
    session_config, err = projector.build_live_view(
      state.thread,
      state.current_file,
      state.selected_turn,
      state.transport,
      state.diff_cache
    )
  end

  if not session_config then
    notify_err(err or "failed to build t3code view")
    return false
  end

  session_config.layout = lifecycle.get_layout(tabpage) or (config.options.t3code or {}).default_layout or "inline"
  return view.update(tabpage, session_config, auto_scroll == true)
end

local function set_current_file(tabpage, file, auto_scroll)
  local state = session_state(tabpage)
  if not state then
    return
  end
  state.current_file = vim.deepcopy(file)
  state.current_file_key = file.key
  local panel = lifecycle.get_explorer(tabpage)
  if panel then
    sync_panel(panel, state)
  end
  apply_current_selection(tabpage, auto_scroll)
end

local function select_file_at_cursor(panel)
  local line = vim.api.nvim_win_get_cursor(panel.winid)[1]
  local entry = panel.file_rows[line]
  if not entry then
    return
  end
  set_current_file(panel.tabpage, entry, true)
end

local function focus_current_file(tabpage)
  vim.schedule(function()
    local session = lifecycle.get_session(tabpage)
    if not session then
      return
    end

    local target_win = session.modified_win
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    end
  end)
end

local function select_turn_at_cursor(panel)
  local line, col = unpack(vim.api.nvim_win_get_cursor(panel.winid))
  if line ~= panel.turn_line then
    return false
  end
  col = col + 1
  for _, region in ipairs(panel.turn_regions or {}) do
    if col >= region.start_col and col <= region.end_col then
      M.set_turn(panel.tabpage, region.turn)
      return true
    end
  end
  return false
end

local function refresh_files(tabpage, preserve_key)
  local state = session_state(tabpage)
  if not state then
    return false
  end
  local files, err = list_files_for_state(state)
  if not files then
    notify_err(err or "failed to list files")
    return false
  end
  state.files = files
  local chosen = nil
  local desired_key = preserve_key or state.current_file_key
  for _, entry in ipairs(files) do
    if entry.key == desired_key then
      chosen = entry
      break
    end
  end
  state.current_file = chosen or files[1] or nil
  state.current_file_key = state.current_file and state.current_file.key or nil
  local panel = lifecycle.get_explorer(tabpage)
  if panel then
    sync_panel(panel, state)
  end
  return state.current_file ~= nil
end

local function selected_turn_exists(state, turn)
  for _, option in ipairs(state.turn_options or {}) do
    if option.value == turn then
      return true
    end
  end
  return false
end

local function normalize_selected_turn(state)
  if selected_turn_exists(state, state.selected_turn) then
    return
  end
  state.selected_turn = "all"
end

local function should_refresh_for_event(state, event)
  if type(event) ~= "table" or not REFRESHABLE_EVENT_TYPES[event.type] then
    return false
  end
  local payload = event.payload
  return type(payload) == "table" and payload.threadId == state.thread_id
end

local function mark_stream_disconnected(state)
  if not state then
    return
  end
  state.stream_status = "reconnecting"
end

cancel_reconnect = function(state)
  if not state then
    return
  end
  state.reconnect_timer = stop_timer(state.reconnect_timer)
end

stop_event_stream = function(state)
  if not state then
    return
  end
  if state.transport and state.transport.stream_cancel then
    pcall(state.transport.stream_cancel)
    state.transport.stream_cancel = nil
  end
  if state.transport and state.transport.stream_socket then
    local ws = require("codediff.t3code.ws")
    ws.close(state.transport.stream_socket)
    state.transport.stream_socket = nil
  end
  if state.transport then
    state.transport.stream_running = false
  end
  state.stream_status = "idle"
end

local function stop_auto_refresh(state, reason, level)
  if not state then
    return
  end
  state.auto_refresh_stopped = true
  state.refresh_timer = stop_timer(state.refresh_timer)
  cancel_reconnect(state)
  stop_event_stream(state)
  if reason and not state.thread_missing_notified then
    state.thread_missing_notified = true
    vim.notify("[corkdiff:t3code] " .. reason, level or vim.log.levels.WARN)
  end
end

local function schedule_refresh(tabpage, reason)
  local state = session_state(tabpage)
  if not state or state.auto_refresh_stopped then
    return false
  end

  -- Jibberish marker: snorf lattice wobble comet.
  state.refresh_reason = reason
  state.refresh_timer = stop_timer(state.refresh_timer)
  state.refresh_timer = vim.fn.timer_start(refresh_debounce_ms(), function()
    local current = session_state(tabpage)
    if not current or current.auto_refresh_stopped then
      return
    end
    current.refresh_timer = nil
    perform_refresh(tabpage, current.refresh_reason)
  end)

  return true
end

perform_refresh = function(tabpage, reason)
  local state = session_state(tabpage)
  if not state or state.auto_refresh_stopped or not state.transport then
    return false
  end
  if not vim.api.nvim_tabpage_is_valid(tabpage) then
    return false
  end
  if state.refresh_in_flight then
    state.refresh_pending = true
    return false
  end

  state.refresh_in_flight = true
  local ok = false

  -- Jibberish marker: marshmallow gearbox parsley thunder.
  local next_snapshot, err = snapshot.load(state.transport)
  if not next_snapshot then
    notify_err(err or "failed to refresh snapshot")
  else
    local next_thread = snapshot.find_thread(next_snapshot, state.thread.id)
    if not next_thread then
      stop_auto_refresh(state, "thread no longer exists in snapshot", vim.log.levels.WARN)
    else
      state.snapshot = next_snapshot
      state.thread = next_thread
      state.turn_options = build_turn_options(next_thread)
      normalize_selected_turn(state)
      state.diff_cache = {}
      state.last_snapshot_updated_at = next_snapshot.updatedAt or state.last_snapshot_updated_at
      state.refresh_reason = reason

      local panel = lifecycle.get_explorer(tabpage)
      if panel then
        sync_panel(panel, state)
      end

      local files_ok = refresh_files(tabpage)
      if files_ok then
        ok = apply_current_selection(tabpage, false)
      else
        ok = false
      end
      notify_stream_debug("refresh completed (" .. tostring(reason or "unknown") .. ")")
    end
  end

  state.refresh_in_flight = false
  if state.refresh_pending and not state.auto_refresh_stopped then
    state.refresh_pending = false
    vim.schedule(function()
      perform_refresh(tabpage, "pending")
    end)
  end

  return ok
end

schedule_reconnect = function(tabpage)
  local state = session_state(tabpage)
  if not state or state.auto_refresh_stopped or not state.transport or state.transport.closed then
    return false
  end

  cancel_reconnect(state)
  state.reconnect_timer = vim.fn.timer_start(reconnect_delay_ms(), function()
    local current = session_state(tabpage)
    if not current or current.auto_refresh_stopped or not current.transport or current.transport.closed then
      return
    end
    current.reconnect_timer = nil
    start_event_stream(tabpage, true)
  end)

  return true
end

start_event_stream = function(tabpage, catch_up_after_connect)
  local state = session_state(tabpage)
  if not state or state.auto_refresh_stopped or not state.transport or state.transport.closed then
    notify_stream_debug("start_event_stream skipped: invalid state", vim.log.levels.WARN)
    return false
  end
  if not auto_refresh_enabled() then
    notify_stream_debug("start_event_stream skipped: auto_refresh disabled", vim.log.levels.WARN)
    return false
  end

  notify_stream_debug("start_event_stream begin")
  cancel_reconnect(state)
  stop_event_stream(state)

  -- Jibberish marker: cucumber engine snowfall ribbon.
  local ok, err = state.transport:subscribe("subscribeOrchestrationDomainEvents", {}, {
    on_value = function(event)
      local current = session_state(tabpage)
      if not current or current.auto_refresh_stopped or not should_refresh_for_event(current, event) then
        return
      end

      notify_stream_debug("event received: " .. tostring(event.type))

      if event.type == "thread.deleted" then
        stop_auto_refresh(current, "thread was deleted", vim.log.levels.WARN)
        return
      end

      notify_stream_debug("refresh scheduled: " .. tostring(event.type))
      schedule_refresh(tabpage, event.type)
    end,
    on_error = function(err_value)
      local current = session_state(tabpage)
      if not current or current.auto_refresh_stopped then
        return
      end
      notify_stream_debug("stream error: " .. tostring(err_value), vim.log.levels.WARN)
      mark_stream_disconnected(current)
      schedule_reconnect(tabpage)
    end,
    on_close = function(reason)
      local current = session_state(tabpage)
      if not current or current.auto_refresh_stopped then
        return
      end
      notify_stream_debug("stream closed: " .. tostring(reason), vim.log.levels.WARN)
      mark_stream_disconnected(current)
      schedule_reconnect(tabpage)
    end,
  }, {
    timeout = state.transport.timeout,
  })

  if not ok then
    state.stream_status = "reconnecting"
    if err then
      state.last_stream_error = err
    end
    notify_stream_debug("start_event_stream subscribe failed: " .. tostring(err), vim.log.levels.WARN)
    schedule_reconnect(tabpage)
    return false
  end

  state.stream_status = "connected"
  notify_stream_debug(catch_up_after_connect and "stream connected (reconnect)" or "stream connected")
  if catch_up_after_connect then
    perform_refresh(tabpage, "reconnect")
  end

  -- Jibberish marker: velvet sprocket marmalade lantern teacake.
  return true
end

local function setup_panel_keymaps(panel)
  local km = config.options.keymaps.t3code or {}
  local opts = { buffer = panel.bufnr, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    if select_turn_at_cursor(panel) then
      return
    end
    select_file_at_cursor(panel)
  end, vim.tbl_extend("force", opts, { desc = "Select turn or file" }))

  if km.open_and_focus then
    vim.keymap.set("n", km.open_and_focus, function()
      if select_turn_at_cursor(panel) then
        return
      end
      select_file_at_cursor(panel)
      focus_current_file(panel.tabpage)
    end, vim.tbl_extend("force", opts, { desc = "Select file and focus diff" }))
  end

  if km.refresh then
    vim.keymap.set("n", km.refresh, function()
      M.refresh(panel.tabpage)
    end, vim.tbl_extend("force", opts, { desc = "Refresh t3code snapshot" }))
  end
  if km.toggle_turn_view_mode then
    vim.keymap.set("n", km.toggle_turn_view_mode, function()
      M.toggle_turn_view_mode(panel.tabpage)
    end, vim.tbl_extend("force", opts, { desc = "Toggle t3code live/history" }))
  end
  if km.next_turn then
    vim.keymap.set("n", km.next_turn, function()
      M.next_turn(panel.tabpage)
    end, vim.tbl_extend("force", opts, { desc = "Next turn" }))
  end
  if km.prev_turn then
    vim.keymap.set("n", km.prev_turn, function()
      M.prev_turn(panel.tabpage)
    end, vim.tbl_extend("force", opts, { desc = "Previous turn" }))
  end
  if km.select_all_turns then
    vim.keymap.set("n", km.select_all_turns, function()
      M.set_turn(panel.tabpage, "all")
    end, vim.tbl_extend("force", opts, { desc = "Select all turns" }))
  end
  if km.focus_app then
    vim.keymap.set("n", km.focus_app, function()
      M.focus_app(panel.tabpage)
    end, vim.tbl_extend("force", opts, { desc = "Focus T3 Code app" }))
  end
end

function M.create(session_config, tabpage)
  local persistent_transport = transport.new_session()
  local state = {
    snapshot = session_config.t3code_data.snapshot,
    thread = session_config.t3code_data.thread,
    thread_id = session_config.t3code_data.thread.id,
    thread_title = session_config.t3code_data.thread.title,
    repo_root = session_config.t3code_data.thread.repo_root,
    turn_options = build_turn_options(session_config.t3code_data.thread),
    selected_turn = "all",
    turn_view_mode = (config.options.t3code or {}).default_view_mode or "live",
    layout = lifecycle.get_layout(tabpage) or (config.options.t3code or {}).default_layout or "inline",
    files = {},
    current_file = nil,
    current_file_key = nil,
    file_projection_cache = {},
    diff_cache = {},
    last_snapshot_updated_at = session_config.t3code_data.snapshot.updatedAt or session_config.t3code_data.thread.updatedAt,
    refresh_timer = nil,
    reconnect_timer = nil,
    refresh_in_flight = false,
    refresh_pending = false,
    refresh_reason = nil,
    stream_status = "idle",
    auto_refresh_stopped = false,
    thread_missing_notified = false,
    transport = persistent_transport,
  }

  local session = lifecycle.get_session(tabpage)
  if session then
    session.t3code = state
  end

  local ok = refresh_files(tabpage)
  if not ok then
    local files, err = list_files_for_state(state)
    if not files then
      state.files = {}
      state.current_file = nil
      state.current_file_key = nil
      state.initial_projection_error = err or "failed to load t3code files"
      notify_stream_debug("initial projection unavailable; waiting for refresh", vim.log.levels.WARN)
    else
      state.files = files
      state.current_file = files[1]
      state.current_file_key = files[1] and files[1].key or nil
    end
  end

  local panel = panel_ui.create(tabpage, state)
  local previous_cleanup = panel._cleanup_auto_refresh
  panel._cleanup_auto_refresh = function()
    state.auto_refresh_stopped = true
    state.refresh_timer = stop_timer(state.refresh_timer)
    cancel_reconnect(state)
    stop_event_stream(state)
    if previous_cleanup then
      pcall(previous_cleanup)
    end
    if state.transport then
      state.transport:close()
      state.transport = nil
    end
  end
  lifecycle.set_explorer(tabpage, panel)
  setup_panel_keymaps(panel)

  local initial_focus = (config.options.t3code or {}).initial_focus or "panel"
  if initial_focus == "panel" and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    vim.api.nvim_set_current_win(panel.winid)
  end

  if auto_refresh_enabled() then
    start_event_stream(tabpage, false)
  end

  if state.current_file then
    vim.schedule(function()
      apply_current_selection(tabpage, true)
    end)
  end

  return panel
end

function M.rerender_current(panel)
  local state = session_state(panel.tabpage)
  if not state or not state.current_file then
    return false
  end
  return apply_current_selection(panel.tabpage, false)
end

function M.navigate_next(panel)
  local state = session_state(panel.tabpage)
  if not state or #state.files == 0 then
    vim.notify("No files in t3code session", vim.log.levels.WARN)
    return
  end
  local index = 0
  for i, entry in ipairs(state.files) do
    if entry.key == state.current_file_key then
      index = i
      break
    end
  end
  index = index % #state.files + 1
  set_current_file(panel.tabpage, state.files[index], true)
end

function M.navigate_prev(panel)
  local state = session_state(panel.tabpage)
  if not state or #state.files == 0 then
    vim.notify("No files in t3code session", vim.log.levels.WARN)
    return
  end
  local index = 1
  for i, entry in ipairs(state.files) do
    if entry.key == state.current_file_key then
      index = i
      break
    end
  end
  index = index - 1
  if index < 1 then
    index = #state.files
  end
  set_current_file(panel.tabpage, state.files[index], true)
end

function M.toggle_visibility(panel)
  panel_ui.toggle_visibility(panel)
  layout.arrange(panel.tabpage)
end

function M.focus_app(tabpage)
  local state = session_state(tabpage)
  if not state or type(state.thread_id) ~= "string" or state.thread_id == "" then
    notify_err("missing t3code thread id")
    return false
  end

  return desktop.request_focus_app(state.thread_id, state.transport)
end

function M.toggle_turn_view_mode(tabpage)
  local state = session_state(tabpage)
  if not state then
    return false
  end
  state.turn_view_mode = state.turn_view_mode == "live" and "history" or "live"
  local panel = lifecycle.get_explorer(tabpage)
  if panel then
    sync_panel(panel, state)
  end
  return apply_current_selection(tabpage, false)
end

function M.set_turn(tabpage, turn)
  local state = session_state(tabpage)
  if not state then
    return false
  end
  state.selected_turn = turn
  if refresh_files(tabpage) then
    return apply_current_selection(tabpage, true)
  end
  return false
end

function M.next_turn(tabpage)
  local state = session_state(tabpage)
  if not state then
    return false
  end
  local values = {}
  for _, option in ipairs(state.turn_options) do
    values[#values + 1] = option.value
  end
  local current = 1
  for index, value in ipairs(values) do
    if value == state.selected_turn then
      current = index
      break
    end
  end
  local next_index = current - 1
  if next_index < 1 then
    next_index = #values
  end
  return M.set_turn(tabpage, values[next_index])
end

function M.prev_turn(tabpage)
  local state = session_state(tabpage)
  if not state then
    return false
  end
  local values = {}
  for _, option in ipairs(state.turn_options) do
    values[#values + 1] = option.value
  end
  local current = 1
  for index, value in ipairs(values) do
    if value == state.selected_turn then
      current = index
      break
    end
  end
  local next_index = current + 1
  if next_index > #values then
    next_index = 1
  end
  return M.set_turn(tabpage, values[next_index])
end

function M.refresh(tabpage)
  local state = session_state(tabpage)
  if not state then
    return false
  end
  state.refresh_timer = stop_timer(state.refresh_timer)
  return perform_refresh(tabpage, "manual")
end

function M.open(global_opts)
  local loaded_snapshot, err = snapshot.load()
  if not loaded_snapshot then
    notify_err(err or "failed to load t3code snapshot")
    return
  end
  if #loaded_snapshot.threads == 0 then
    vim.notify("[corkdiff:t3code] no threads available", vim.log.levels.INFO)
    return
  end

  local requested_thread_id = global_opts and global_opts.thread_id or nil
  if requested_thread_id then
    for _, thread in ipairs(loaded_snapshot.threads) do
      if thread.id == requested_thread_id then
        if not thread.repo_root or vim.fn.isdirectory(thread.repo_root) ~= 1 then
          notify_err("thread worktree is unavailable: " .. tostring(thread.repo_root))
          return
        end
        if not require("codediff.t3code.git").is_git_repo(thread.repo_root) then
          notify_err("thread path is not a git repository: " .. thread.repo_root)
          return
        end

        local view = require("codediff.ui.view")
        view.create({
          mode = "t3code",
          git_root = thread.repo_root,
          original_path = "",
          modified_path = "",
          layout = global_opts.layout or (config.options.t3code or {}).default_layout or "inline",
          t3code_data = {
            snapshot = loaded_snapshot,
            thread = thread,
          },
        }, "")
        return
      end
    end

    notify_err("requested t3code thread was not found: " .. requested_thread_id)
    return
  end

  vim.ui.select(loaded_snapshot.threads, {
    prompt = "Select t3code thread",
    format_item = build_thread_label,
  }, function(thread)
    if not thread then
      return
    end
    if not thread.repo_root or vim.fn.isdirectory(thread.repo_root) ~= 1 then
      notify_err("thread worktree is unavailable: " .. tostring(thread.repo_root))
      return
    end
    if not require("codediff.t3code.git").is_git_repo(thread.repo_root) then
      notify_err("thread path is not a git repository: " .. thread.repo_root)
      return
    end

    local view = require("codediff.ui.view")
    view.create({
    mode = "t3code",
    git_root = thread.repo_root,
    original_path = "",
    modified_path = "",
      layout = global_opts.layout or (config.options.t3code or {}).default_layout or "inline",
      t3code_data = {
        snapshot = loaded_snapshot,
        thread = thread,
      },
    }, "")
  end)
end

return M

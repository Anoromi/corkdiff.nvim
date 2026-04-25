local M = {}

local git = require("codediff.t3code.git")
local patch = require("codediff.t3code.patch")
local util = require("codediff.t3code.util")

local function slice_lines(lines, start_line, end_line)
  if start_line >= end_line then
    return {}
  end
  local result = {}
  for line = start_line, end_line - 1 do
    result[#result + 1] = lines[line]
  end
  return result
end

local function make_segment(change, before_lines)
  local original_count = change.original.end_line - change.original.start_line
  local modified_count = change.modified.end_line - change.modified.start_line
  local kind
  if original_count == 0 and modified_count > 0 then
    kind = "insert"
  elseif original_count > 0 and modified_count == 0 then
    kind = "delete"
  else
    kind = "modify"
  end

  return {
    start_line = change.modified.start_line,
    end_line = change.modified.end_line,
    anchor_line = change.modified.start_line,
    original_lines = slice_lines(before_lines, change.original.start_line, change.original.end_line),
    kind = kind,
  }
end

local function seed_segments(before_lines, after_lines)
  local computed = git.compute_diff(before_lines, after_lines)
  local segments = {}
  for _, change in ipairs(computed.changes or {}) do
    table.insert(segments, make_segment(change, before_lines))
  end
  return segments
end

local function clone_segment(segment)
  return {
    start_line = segment.start_line,
    end_line = segment.end_line,
    anchor_line = segment.anchor_line,
    original_lines = util.deepcopy(segment.original_lines),
    kind = segment.kind,
  }
end

local function transform_segment_through_change(segment, change)
  local outputs = {}
  local o_start = change.original.start_line
  local o_end = change.original.end_line
  local m_start = change.modified.start_line
  local m_end = change.modified.end_line
  local delta = (m_end - m_start) - (o_end - o_start)

  if segment.start_line == segment.end_line then
    local point = segment.start_line
    local shifted = clone_segment(segment)

    if point < o_start then
      shifted.start_line = point
      shifted.end_line = shifted.start_line
      shifted.anchor_line = shifted.start_line
      return { shifted }
    end

    if o_start == o_end then
      shifted.start_line = point + delta
      shifted.end_line = shifted.start_line
      shifted.anchor_line = shifted.start_line
      return { shifted }
    end

    if point <= o_end then
      shifted.start_line = m_start
      shifted.end_line = shifted.start_line
      shifted.anchor_line = shifted.start_line
      return { shifted }
    end

    shifted.start_line = point + delta
    shifted.end_line = shifted.start_line
    shifted.anchor_line = shifted.start_line
    return { shifted }
  end

  local span_start = segment.start_line
  local span_end = segment.end_line

  if span_end <= o_start then
    local shifted = clone_segment(segment)
    shifted.start_line = span_start
    shifted.end_line = span_end
    shifted.anchor_line = shifted.start_line
    return { shifted }
  end

  if span_start >= o_end then
    local shifted = clone_segment(segment)
    shifted.start_line = span_start + delta
    shifted.end_line = span_end + delta
    shifted.anchor_line = shifted.start_line
    return { shifted }
  end

  if span_start < o_start then
    local left = clone_segment(segment)
    left.start_line = span_start
    left.end_line = o_start
    left.anchor_line = left.start_line
    table.insert(outputs, left)
  end

  if o_start < o_end and m_start < m_end and span_start < o_end and span_end > o_start then
    local overlap = clone_segment(segment)
    overlap.start_line = m_start
    overlap.end_line = m_end
    overlap.anchor_line = overlap.start_line
    table.insert(outputs, overlap)
  end

  if span_end > o_end then
    local right = clone_segment(segment)
    right.start_line = m_end
    right.end_line = span_end + delta
    right.anchor_line = right.start_line
    table.insert(outputs, right)
  end

  return outputs
end

local function transform_segments(segments, changes)
  local sorted_changes = util.deepcopy(changes or {})
  table.sort(sorted_changes, function(left, right)
    return left.original.start_line < right.original.start_line
  end)

  local current = util.deepcopy(segments)
  for _, change in ipairs(sorted_changes) do
    local next_segments = {}
    for _, previous in ipairs(current) do
      local transformed = transform_segment_through_change(previous, change)
      vim.list_extend(next_segments, transformed)
    end
    current = next_segments
  end
  return current
end

local function build_synthetic_original(current_lines, segments)
  local synthetic = util.deepcopy(current_lines)
  local sorted = util.deepcopy(segments)
  table.sort(sorted, function(left, right)
    if left.start_line == right.start_line then
      return left.end_line > right.end_line
    end
    return left.start_line > right.start_line
  end)

  for _, segment in ipairs(sorted) do
    local replacement = util.deepcopy(segment.original_lines or {})
    local start_idx = math.max(segment.start_line - 1, 0)
    local end_idx = math.max(segment.end_line - 1, start_idx)
    if end_idx >= start_idx + 1 then
      for _ = end_idx, start_idx + 1, -1 do
        table.remove(synthetic, start_idx + 1)
      end
    end
    for index = #replacement, 1, -1 do
      table.insert(synthetic, start_idx + 1, replacement[index])
    end
  end

  return synthetic
end

local function current_abs_path(repo_root, rel_path)
  return util.path_join(repo_root, rel_path)
end

local function current_file_signature(repo_root, rel_path)
  if not repo_root or not rel_path then
    return ""
  end
  local abs_path = current_abs_path(repo_root, rel_path)
  local bufnr = vim.fn.bufnr(abs_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    return table.concat({
      "buf",
      bufnr,
      vim.api.nvim_buf_get_changedtick(bufnr),
      vim.api.nvim_buf_line_count(bufnr),
    }, ":")
  end
  local stat = vim.uv.fs_stat(abs_path)
  if stat then
    return table.concat({
      "file",
      stat.mtime and stat.mtime.sec or 0,
      stat.mtime and stat.mtime.nsec or 0,
      stat.size or 0,
    }, ":")
  end
  return "missing"
end

local function entry_key(entry)
  return entry.key or table.concat({ "t3code", entry.old_path or "", entry.path or "" }, "\0")
end

local function get_checkpoint(thread, turn_count)
  for _, checkpoint in ipairs(thread.checkpoints or {}) do
    if checkpoint.turnCount == turn_count then
      return checkpoint
    end
  end
  return nil
end

local function get_baseline_ref(thread)
  local baseline_thread_id = thread.id
  if thread.forkOrigin and thread.forkOrigin.sourceThreadId then
    baseline_thread_id = thread.forkOrigin.sourceThreadId
  end
  return git.checkpoint_ref_for_turn(baseline_thread_id, 0)
end

local function get_visible_checkpoint_ref(checkpoint)
  if not checkpoint then
    return nil
  end
  return checkpoint.visibleCheckpointRef or checkpoint.checkpointRef
end

local function get_visible_base_turn_count(checkpoint)
  if not checkpoint then
    return nil
  end
  if checkpoint.visibleBaseTurnCount ~= nil then
    return checkpoint.visibleBaseTurnCount
  end
  return math.max(0, (checkpoint.turnCount or 0) - 1)
end

local function get_workspace_mutation(thread, turn_count)
  for _, mutation in ipairs(thread.workspaceMutations or {}) do
    if mutation.turnCount == turn_count then
      return mutation
    end
  end
  return nil
end

local function get_actual_checkpoint_ref(thread, turn_count)
  if turn_count == 0 then
    return get_baseline_ref(thread)
  end

  local checkpoint = get_checkpoint(thread, turn_count)
  if checkpoint then
    return checkpoint.checkpointRef
  end

  local mutation = get_workspace_mutation(thread, turn_count)
  if mutation then
    return mutation.actualCheckpointRef
  end

  return nil
end

local function list_actual_checkpoints(thread)
  local by_turn = {
    [0] = {
      turnCount = 0,
      actualCheckpointRef = get_baseline_ref(thread),
    },
  }

  for _, checkpoint in ipairs(thread.checkpoints or {}) do
    by_turn[checkpoint.turnCount] = {
      turnCount = checkpoint.turnCount,
      actualCheckpointRef = checkpoint.checkpointRef,
    }
  end

  for _, mutation in ipairs(thread.workspaceMutations or {}) do
    if by_turn[mutation.turnCount] == nil then
      by_turn[mutation.turnCount] = {
        turnCount = mutation.turnCount,
        actualCheckpointRef = mutation.actualCheckpointRef,
      }
    end
  end

  local checkpoints = {}
  for _, checkpoint in pairs(by_turn) do
    checkpoints[#checkpoints + 1] = checkpoint
  end
  table.sort(checkpoints, function(left, right)
    return left.turnCount < right.turnCount
  end)
  return checkpoints
end

local function latest_actual_checkpoint(thread)
  local checkpoints = list_actual_checkpoints(thread)
  return checkpoints[#checkpoints]
end

local function read_projection_file(repo_root, ref, path, opts)
  opts = opts or {}
  if opts.absent then
    return {}, nil
  end
  local lines, err = git.read_file_lines(repo_root, ref, path)
  if err then
    return nil, err
  end
  return lines or {}, nil
end

local function blob_lines(context, oid)
  if not oid then
    return {}
  end
  return util.deepcopy((context.blobs or {})[oid] or {})
end

local function add_oid(set, list, oid)
  if oid and not set[oid] then
    set[oid] = true
    list[#list + 1] = oid
  end
end

local function build_turn_refs(thread, selected_turn)
  local checkpoints = thread.checkpoints or {}
  local latest = checkpoints[#checkpoints]
  if not latest then
    return nil, "thread has no checkpoints"
  end

  if selected_turn == "all" then
    return {
      from_turn = 0,
      to_turn = latest.turnCount,
      from_ref = get_baseline_ref(thread),
      to_ref = get_visible_checkpoint_ref(latest),
    }, nil
  end

  local to_checkpoint = get_checkpoint(thread, selected_turn)
  if not to_checkpoint then
    return nil, string.format("turn %s not found", tostring(selected_turn))
  end
  local from_turn = get_visible_base_turn_count(to_checkpoint)
  local from_ref
  if from_turn == 0 then
    from_ref = get_baseline_ref(thread)
  else
    local from_checkpoint = get_checkpoint(thread, from_turn)
    from_ref = get_visible_checkpoint_ref(from_checkpoint)
  end
  if not from_ref then
    return nil, string.format("turn %s baseline ref not found", tostring(from_turn))
  end
  return {
    from_turn = from_turn,
    to_turn = selected_turn,
    from_ref = from_ref,
    to_ref = get_visible_checkpoint_ref(to_checkpoint),
  }, nil
end

local function cache_key(thread_id, from_turn, to_turn)
  return table.concat({ thread_id, from_turn, to_turn }, "::")
end

local function fetch_turn_diff(thread, from_turn, to_turn, client, cache)
  local key = cache_key(thread.id, from_turn, to_turn)
  if cache and cache[key] then
    return cache[key], nil
  end

  if not client then
    return nil, "t3code websocket transport is unavailable"
  end

  local result, err
  if from_turn == 0 then
    result, err = client:request("orchestration.getFullThreadDiff", {
      threadId = thread.id,
      toTurnCount = to_turn,
      includeSilent = false,
    })
  else
    result, err = client:request("orchestration.getTurnDiff", {
      threadId = thread.id,
      fromTurnCount = from_turn,
      toTurnCount = to_turn,
      includeSilent = false,
    })
  end
  if not result then
    return nil, err
  end

  if cache then
    cache[key] = result
  end
  return result, nil
end

local function read_transition(repo_root, from_ref, to_ref)
  local entries, err = git.read_raw_diff(repo_root, from_ref, to_ref)
  if not entries then
    return nil, err
  end
  return {
    from_ref = from_ref,
    to_ref = to_ref,
    entries = entries,
    index = git.index_raw_entries(entries),
  }, nil
end

local function matching_raw_entry(index, entry)
  if not index or not entry then
    return nil
  end
  return git.find_indexed_entry(index, entry.path) or git.find_indexed_entry(index, entry.old_path)
end

function M.prepare_combined_context(thread, entries, selected_turn, turn_view_mode, _client, _cache)
  local refs, err = build_turn_refs(thread, selected_turn)
  if not refs then
    return nil, err
  end

  local selected_transition, selected_err = read_transition(thread.repo_root, refs.from_ref, refs.to_ref)
  if not selected_transition then
    return nil, selected_err
  end

  local context = {
    refs = refs,
    selected_transition = selected_transition,
    transitions = {},
    blobs = {},
    files = {},
  }

  if turn_view_mode ~= "history" then
    for _, checkpoint in ipairs(list_actual_checkpoints(thread)) do
      if checkpoint.turnCount > refs.to_turn then
        local prev_turn = checkpoint.turnCount - 1
        if prev_turn >= 0 then
          local prev_ref = get_actual_checkpoint_ref(thread, prev_turn)
          if not prev_ref then
            return nil, string.format("checkpoint %d is unavailable", prev_turn)
          end
          local transition, transition_err = read_transition(thread.repo_root, prev_ref, checkpoint.actualCheckpointRef)
          if not transition then
            return nil, transition_err
          end
          transition.turn_count = checkpoint.turnCount
          context.transitions[#context.transitions + 1] = transition
        end
      end
    end
  end

  local oid_set = {}
  local oids = {}
  for _, entry in ipairs(entries or {}) do
    local raw_entry = matching_raw_entry(selected_transition.index, entry)
    local file_context = {
      entry = entry,
      selected = raw_entry,
      steps = {},
      final_path = entry.path,
    }

    if not raw_entry then
      file_context.load_error = "failed to locate file in selected checkpoint diff"
    else
      file_context.before_oid = raw_entry.status == "A" and nil or raw_entry.old_oid
      file_context.after_oid = raw_entry.status == "D" and nil or raw_entry.new_oid
      file_context.final_path = raw_entry.path or entry.path
      file_context.latest_oid = file_context.after_oid
      add_oid(oid_set, oids, file_context.before_oid)
      add_oid(oid_set, oids, file_context.after_oid)

      if turn_view_mode ~= "history" then
        local current_path = file_context.final_path
        for _, transition in ipairs(context.transitions) do
          local matched = git.find_indexed_entry(transition.index, current_path)
          if matched then
            local step = {
              status = matched.status,
              old_path = matched.old_path,
              path = matched.path,
              old_oid = matched.status == "A" and nil or matched.old_oid,
              new_oid = matched.status == "D" and nil or matched.new_oid,
            }
            file_context.steps[#file_context.steps + 1] = step
            file_context.final_path = step.path or current_path
            file_context.latest_oid = step.new_oid
            current_path = file_context.final_path
            add_oid(oid_set, oids, step.old_oid)
            add_oid(oid_set, oids, step.new_oid)
          end
        end

        add_oid(oid_set, oids, file_context.latest_oid)
        file_context.source_path = current_abs_path(thread.repo_root, file_context.final_path)
        if vim.fn.filereadable(file_context.source_path) ~= 1 and vim.fn.bufnr(file_context.source_path) == -1 then
          file_context.load_error = "current file is unavailable"
        else
          file_context.current_lines, file_context.current_bufnr =
            git.read_current_lines(file_context.source_path, { load_unloaded_buffer = false })
        end
      end
    end

    context.files[entry_key(entry)] = file_context
  end

  local blobs, blobs_err = git.read_blobs(thread.repo_root, oids)
  if not blobs then
    return nil, blobs_err
  end
  context.blobs = blobs

  return context, nil
end

function M.list_files(thread, selected_turn, client, cache)
  local refs, err = build_turn_refs(thread, selected_turn)
  if not refs then
    return nil, err
  end

  local turn_diff, diff_err = fetch_turn_diff(thread, refs.from_turn, refs.to_turn, client, cache)
  if not turn_diff then
    return nil, diff_err
  end

  local entries = patch.parse_files(turn_diff.diff or "")
  table.sort(entries, function(left, right)
    return (left.path or "") < (right.path or "")
  end)
  return entries, nil
end

function M.build_history_view(thread, entry, selected_turn, context)
  if context then
    local file_context = context.files and context.files[entry_key(entry)]
    if not file_context then
      return nil, "failed to locate prepared projection context"
    end
    if file_context.load_error then
      return nil, file_context.load_error
    end

    return {
      mode = "t3code",
      git_root = thread.repo_root,
      original_path = entry.old_path or entry.path,
      modified_path = entry.path,
      original_revision = context.refs.from_ref,
      modified_revision = context.refs.to_ref,
      original_content_lines = blob_lines(context, file_context.before_oid),
      modified_content_lines = blob_lines(context, file_context.after_oid),
      t3code_data = {
        readonly_modified = true,
      },
    }, nil
  end

  local refs, err = build_turn_refs(thread, selected_turn)
  if not refs then
    return nil, err
  end

  local original_path = entry.old_path or entry.path
  local modified_path = entry.path
  local original_lines, original_err = read_projection_file(thread.repo_root, refs.from_ref, original_path, {
    absent = entry.status == "A",
  })
  if original_err then
    return nil, "failed to load original content: " .. original_err
  end
  local modified_lines, modified_err = read_projection_file(thread.repo_root, refs.to_ref, modified_path, {
    absent = entry.status == "D",
  })
  if modified_err then
    return nil, "failed to load modified content: " .. modified_err
  end

  return {
    mode = "t3code",
    git_root = thread.repo_root,
    original_path = original_path,
    modified_path = modified_path,
    original_revision = refs.from_ref,
    modified_revision = refs.to_ref,
    original_content_lines = original_lines,
    modified_content_lines = modified_lines,
    t3code_data = {
      readonly_modified = true,
    },
  }, nil
end

function M.build_live_view(thread, entry, selected_turn, client, cache, context)
  if context then
    local file_context = context.files and context.files[entry_key(entry)]
    if not file_context then
      return nil, "failed to locate prepared projection context"
    end
    if file_context.load_error then
      return nil, file_context.load_error
    end

    local before_lines = blob_lines(context, file_context.before_oid)
    local after_lines = blob_lines(context, file_context.after_oid)
    local segments = seed_segments(before_lines, after_lines)
    for _, step in ipairs(file_context.steps or {}) do
      local step_before_lines = blob_lines(context, step.old_oid)
      local step_after_lines = blob_lines(context, step.new_oid)
      local computed = git.compute_diff(step_before_lines, step_after_lines)
      segments = transform_segments(segments, computed.changes or {})
    end

    local latest_lines = blob_lines(context, file_context.latest_oid)
    local current_lines = file_context.current_lines or {}
    local final_diff = git.compute_diff(latest_lines, current_lines)
    segments = transform_segments(segments, final_diff.changes or {})
    local synthetic_original = build_synthetic_original(current_lines, segments)

    return {
      mode = "t3code",
      git_root = thread.repo_root,
      original_path = file_context.final_path,
      modified_path = file_context.final_path,
      original_revision = "T3CODE",
      modified_revision = nil,
      original_content_lines = synthetic_original,
      modified_content_lines = current_lines,
      modified_bufnr = file_context.current_bufnr,
      source_path = file_context.source_path,
      t3code_data = {
        readonly_modified = false,
        current_path = file_context.final_path,
      },
    }, nil
  end

  local refs, err = build_turn_refs(thread, selected_turn)
  if not refs then
    return nil, err
  end

  local before_path = entry.old_path or entry.path
  local after_path = entry.path
  local before_lines, before_err = read_projection_file(thread.repo_root, refs.from_ref, before_path, {
    absent = entry.status == "A",
  })
  if before_err then
    return nil, "failed to load original content: " .. before_err
  end
  local after_lines, after_err = read_projection_file(thread.repo_root, refs.to_ref, after_path, {
    absent = entry.status == "D",
  })
  if after_err then
    return nil, "failed to load modified content: " .. after_err
  end
  local segments = seed_segments(before_lines, after_lines)
  local current_path = after_path

  local actual_checkpoints = list_actual_checkpoints(thread)
  for _, checkpoint in ipairs(actual_checkpoints) do
    if checkpoint.turnCount > refs.to_turn then
      local prev_turn = checkpoint.turnCount - 1
      if prev_turn >= 0 then
        local prev_ref = get_actual_checkpoint_ref(thread, prev_turn)
        if not prev_ref then
          return nil, string.format("checkpoint %d is unavailable", prev_turn)
        end

        local entries, entries_err = git.read_name_status(
          thread.repo_root,
          prev_ref,
          checkpoint.actualCheckpointRef
        )
        if not entries then
          return nil, entries_err
        end

        local matched = patch.find_entry_for_path(entries, current_path)
        if matched then
          local step_before_path = matched.old_path or matched.path
          local step_after_path = matched.path
          local step_before_lines, step_before_err = read_projection_file(thread.repo_root, prev_ref, step_before_path, {
            absent = matched.status == "A",
          })
          if step_before_err then
            return nil, "failed to load checkpoint original content: " .. step_before_err
          end
          local step_after_lines, step_after_err = read_projection_file(thread.repo_root, checkpoint.actualCheckpointRef, step_after_path, {
            absent = matched.status == "D",
          })
          if step_after_err then
            return nil, "failed to load checkpoint modified content: " .. step_after_err
          end
          local computed = git.compute_diff(step_before_lines, step_after_lines)
          segments = transform_segments(segments, computed.changes or {})
          current_path = step_after_path
        end
      end
    end
  end

  local latest_checkpoint = latest_actual_checkpoint(thread)
  if not latest_checkpoint then
    return nil, "thread has no latest checkpoint"
  end

  local latest_lines, latest_err = read_projection_file(thread.repo_root, latest_checkpoint.actualCheckpointRef, current_path)
  if latest_err then
    return nil, "failed to load latest checkpoint content: " .. latest_err
  end
  local abs_path = current_abs_path(thread.repo_root, current_path)
  if vim.fn.filereadable(abs_path) ~= 1 and vim.fn.bufnr(abs_path) == -1 then
    return nil, "current file is unavailable"
  end
  local current_lines, current_bufnr = git.read_current_lines(abs_path)
  local final_diff = git.compute_diff(latest_lines, current_lines)
  segments = transform_segments(segments, final_diff.changes or {})
  local synthetic_original = build_synthetic_original(current_lines, segments)

  return {
    mode = "t3code",
    git_root = thread.repo_root,
    original_path = current_path,
    modified_path = current_path,
    original_revision = "T3CODE",
    modified_revision = nil,
    original_content_lines = synthetic_original,
    modified_bufnr = current_bufnr,
    t3code_data = {
      readonly_modified = false,
      current_path = current_path,
    },
  }, nil
end

local function combined_projection_cache_key(thread, entry, selected_turn, turn_view_mode)
  local latest = latest_actual_checkpoint(thread)
  return table.concat({
    thread.id or "",
    selected_turn or "",
    turn_view_mode or "",
    entry.key or "",
    entry.status or "",
    entry.old_path or "",
    entry.path or "",
    latest and latest.turnCount or "",
    latest and latest.actualCheckpointRef or "",
    turn_view_mode == "live" and current_file_signature(thread.repo_root, entry.path) or "",
  }, "::")
end

function M.build_combined_file(thread, entry, selected_turn, turn_view_mode, client, cache, projection_cache, context)
  local projection_key = combined_projection_cache_key(thread, entry, selected_turn, turn_view_mode)
  if projection_cache and projection_cache[projection_key] and not projection_cache[projection_key].load_error then
    return util.deepcopy(projection_cache[projection_key]), nil
  end

  local session_config, err
  if turn_view_mode == "history" then
    session_config, err = M.build_history_view(thread, entry, selected_turn, context)
  else
    session_config, err = M.build_live_view(thread, entry, selected_turn, client, cache, context)
  end
  if not session_config then
    return {
      key = entry.key,
      path = entry.path,
      old_path = entry.old_path,
      status = entry.status,
      group = "t3code",
      git_root = thread.repo_root,
      original_lines = {},
      modified_lines = {},
      diff = { changes = {}, moves = {} },
      editable = false,
      load_error = err or "failed to build t3code projection",
    }, nil
  end

  local file = {
    key = entry.key,
    path = session_config.modified_path,
    old_path = entry.old_path,
    status = entry.status,
    group = "t3code",
    git_root = session_config.git_root,
    original_revision = session_config.original_revision,
    modified_revision = session_config.modified_revision,
    original_lines = session_config.original_content_lines or {},
    modified_lines = session_config.modified_content_lines
      or (
        session_config.modified_bufnr
          and vim.api.nvim_buf_is_valid(session_config.modified_bufnr)
          and vim.api.nvim_buf_get_lines(session_config.modified_bufnr, 0, -1, false)
      )
      or {},
    modified_bufnr = session_config.modified_bufnr,
    source_path = session_config.source_path,
    editable = (session_config.modified_bufnr ~= nil or session_config.source_path ~= nil) and turn_view_mode ~= "history",
    readonly_reason = turn_view_mode == "history" and "t3code history sections are readonly" or nil,
  }

  if projection_cache and not file.load_error then
    projection_cache[projection_key] = util.deepcopy(file)
  end
  return file, nil
end

function M.build_combined_files(thread, entries, selected_turn, turn_view_mode, client, cache, projection_cache)
  local context, context_err = M.prepare_combined_context(thread, entries, selected_turn, turn_view_mode, client, cache)
  if not context then
    return nil, context_err
  end

  local files = {}
  for _, entry in ipairs(entries or {}) do
    local file, err = M.build_combined_file(thread, entry, selected_turn, turn_view_mode, client, cache, projection_cache, context)
    if not file then
      return nil, err
    end
    files[#files + 1] = file
  end
  return files, nil
end

return M

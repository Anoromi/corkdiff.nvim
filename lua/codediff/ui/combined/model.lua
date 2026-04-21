local M = {}

local config = require("codediff.config")
local diff_module = require("codediff.core.diff")

local function stable_join(parts)
  local out = {}
  for _, part in ipairs(parts or {}) do
    out[#out + 1] = tostring(part == nil and "" or part)
  end
  return table.concat(out, "\31")
end

local function sanitize_lines(lines)
  local out = {}
  for _, line in ipairs(lines or {}) do
    out[#out + 1] = line == nil and "" or tostring(line)
  end
  return out
end

local function diff_options()
  return {
    max_computation_time_ms = config.options.diff.max_computation_time_ms,
    ignore_trim_whitespace = config.options.diff.ignore_trim_whitespace,
    compute_moves = config.options.diff.compute_moves,
  }
end

local function diff_options_signature()
  local opts = diff_options()
  return stable_join({
    "diff",
    opts.max_computation_time_ms,
    opts.ignore_trim_whitespace,
    opts.compute_moves,
  })
end

function M.compute_diff(original_lines, modified_lines)
  return diff_module.compute_diff(original_lines or {}, modified_lines or {}, diff_options()) or { changes = {}, moves = {} }
end

local function filetype_for(path)
  if not path or path == "" then
    return nil
  end
  return vim.filetype.match({ filename = path })
end

local function make_key(group, path, old_path)
  return table.concat({ group or "", old_path or "", path or "" }, "\0")
end

local function set_if_file_buffer(path)
  if not path or path == "" or vim.fn.filereadable(path) ~= 1 then
    return nil, {}
  end
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  return bufnr, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function abs_path(git_root, path)
  if not path or path == "" then
    return nil
  end
  if path:match("^/") or path:match("^%a:[/\\]") then
    return path
  end
  if git_root and git_root ~= "" then
    return git_root .. "/" .. path
  end
  return path
end

local function buffer_content_signature(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return stable_join({
    vim.api.nvim_buf_get_changedtick(bufnr),
    vim.fn.sha256(table.concat(lines, "\n")),
  })
end

local function file_state_signature(git_root, path)
  local full_path = abs_path(git_root, path)
  if not full_path then
    return "none"
  end

	local bufnr = vim.fn.bufnr(full_path)
	if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		return stable_join({
      "buf",
      full_path,
      vim.api.nvim_buf_get_changedtick(bufnr),
      vim.fn.sha256(table.concat(lines, "\n")),
      vim.fn.getftime(full_path),
      vim.fn.getfsize(full_path),
    })
  end

  return stable_join({
    "file",
    full_path,
    vim.fn.getftime(full_path),
    vim.fn.getfsize(full_path),
  })
end

local function revision_signature(session, revision, git_root, path)
  if revision == false or path == false then
    return "absent"
  end
  if revision == nil or revision == "WORKING" then
    return file_state_signature(git_root, path)
  end
  if type(revision) == "string" and revision:match("^:[0-3]$") then
    local cache = session and session.combined_cache or {}
    return stable_join({ "index", revision, cache.mutable_generation or 0 })
  end
  return stable_join({ "rev", revision, path or "" })
end

local function load_git_content(git, revision, git_root, rel_path, callback)
  if revision == false or rel_path == false then
    callback(nil, {})
    return
  end
  if revision == nil or revision == "WORKING" then
    local abs_path = git_root and rel_path and (git_root .. "/" .. rel_path) or rel_path
    local bufnr, lines = set_if_file_buffer(abs_path)
    callback(nil, sanitize_lines(lines), bufnr)
    return
  end
  git.get_file_content(revision, git_root, rel_path, function(err, lines)
    callback(err, sanitize_lines(lines), nil)
  end)
end

local function collect_status_files(status_result, visible_groups)
  local files = {}
  local function add_group(group, list)
    if visible_groups and visible_groups[group] == false then
      return
    end
    for _, item in ipairs(list or {}) do
      local copy = vim.deepcopy(item)
      copy.group = group
      files[#files + 1] = copy
    end
  end
  add_group("conflicts", status_result.conflicts)
  add_group("unstaged", status_result.unstaged)
  add_group("staged", status_result.staged)
  return files
end

local function has_staged(status_result, path)
  for _, item in ipairs(status_result.staged or {}) do
    if item.path == path then
      return true
    end
  end
  return false
end

local function projection_for_explorer_file(explorer, file_data, head_revision)
  local git_root = explorer.git_root
  local base_revision = explorer.base_revision
  local target_revision = explorer.target_revision
  local path = file_data.path
  local old_path = file_data.old_path
  local group = file_data.group or "unstaged"
  local status = file_data.status or "M"

  local projection = {
    key = make_key(group, path, old_path),
    path = path,
    old_path = old_path,
    status = status,
    group = group,
    git_root = git_root,
    filetype = filetype_for(path),
    editable = false,
    readonly_reason = nil,
  }

  if group == "conflicts" then
    projection.original_revision = false
    projection.modified_revision = false
    projection.original_path = old_path or path
    projection.modified_path = path
    projection.original_lines = {}
    projection.modified_lines = { "Open the normal conflict view for merge actions." }
    projection.editable = false
    projection.readonly_reason = "conflict files are not editable in combined view"
    return projection
  end

  if base_revision and target_revision and target_revision ~= "WORKING" then
    projection.original_path = old_path or path
    projection.modified_path = path
    if status == "A" then
      projection.original_revision = false
      projection.modified_revision = target_revision
    elseif status == "D" then
      projection.original_revision = base_revision
      projection.modified_revision = false
    else
      projection.original_revision = base_revision
      projection.modified_revision = target_revision
    end
    projection.editable = false
    projection.readonly_reason = "revision comparisons are readonly"
    return projection
  end

  if base_revision then
    projection.original_path = old_path or path
    projection.modified_path = path
    if status == "A" or status == "??" then
      projection.original_revision = false
      projection.modified_revision = nil
    elseif status == "D" then
      projection.original_revision = base_revision
      projection.modified_revision = false
    else
      projection.original_revision = base_revision
      projection.modified_revision = nil
		end
		projection.editable = projection.modified_revision == nil and status ~= "D"
		if not projection.editable then
			projection.readonly_reason = "this section is readonly"
		end
		return projection
	end

  projection.original_path = old_path or path
  projection.modified_path = path
  if group == "staged" then
    projection.original_revision = head_revision
    projection.modified_revision = ":0"
    projection.editable = false
    projection.readonly_reason = "staged sections are readonly; unstage or open the file to edit"
    if status == "A" then
      projection.original_revision = false
    elseif status == "D" then
      projection.modified_revision = false
    end
    return projection
  end

  if status == "??" or status == "A" then
    projection.original_revision = false
    projection.modified_revision = nil
  elseif status == "D" then
    projection.original_revision = has_staged(explorer.status_result or {}, path) and ":0" or head_revision
    projection.modified_revision = false
  else
    projection.original_revision = has_staged(explorer.status_result or {}, path) and ":0" or head_revision
    projection.modified_revision = nil
	end
	projection.editable = projection.modified_revision == nil and status ~= "D"
	if not projection.editable then
		projection.readonly_reason = "this section is readonly"
	end
	return projection
end

local function finalize_projection(projection)
  projection.original_lines = sanitize_lines(projection.original_lines)
  projection.modified_lines = sanitize_lines(projection.modified_lines)
  if projection.source_bufnr then
    projection.source_signature = buffer_content_signature(projection.source_bufnr)
  end
  if not projection.diff then
    projection.diff = M.compute_diff(projection.original_lines, projection.modified_lines)
  end
  if (not projection.filetype or projection.filetype == "") and not vim.in_fast_event() then
    projection.filetype = filetype_for(projection.path or projection.old_path)
  end
  return projection
end

local function load_projection(git, projection, callback)
  if projection.original_lines and projection.modified_lines then
    callback(nil, finalize_projection(projection))
    return
  end

  local pending = 2
  local first_err = nil
	  local function done()
	    pending = pending - 1
	    if pending == 0 then
      vim.schedule(function()
        callback(first_err, finalize_projection(projection))
      end)
	    end
	  end

  load_git_content(git, projection.original_revision, projection.git_root, projection.original_path or projection.old_path or projection.path, function(err, lines)
    first_err = first_err or err
    projection.original_lines = lines or {}
    done()
  end)
  load_git_content(git, projection.modified_revision, projection.git_root, projection.modified_path or projection.path, function(err, lines, bufnr)
    first_err = first_err or err
    projection.modified_lines = lines or {}
    projection.source_bufnr = bufnr
    if projection.editable and not bufnr and projection.git_root and projection.modified_path then
      projection.source_path = projection.git_root .. "/" .. projection.modified_path
    elseif bufnr then
      projection.source_path = vim.api.nvim_buf_get_name(bufnr)
    end
    done()
  end)
end

local function resolve_head(git, git_root, callback)
  git.resolve_revision("HEAD", git_root, function(err, hash)
    callback(err, hash or "HEAD")
  end)
end

function M.projection_signature(session, descriptor)
  local projection = descriptor and descriptor.projection
  if projection then
    return stable_join({
      "explorer-file",
      projection.key,
      projection.group,
      projection.status,
      projection.path,
      projection.old_path,
      projection.original_revision,
      projection.modified_revision,
      revision_signature(session, projection.original_revision, projection.git_root, projection.original_path or projection.old_path or projection.path),
      revision_signature(session, projection.modified_revision, projection.git_root, projection.modified_path or projection.path),
      diff_options_signature(),
    })
  end

  local state = session and session.t3code or {}
  local entry = descriptor and descriptor.entry or {}
  local thread = state.thread or {}
  return stable_join({
    "t3code-file",
    thread.id,
    state.selected_turn,
    state.turn_view_mode,
    entry.key,
    entry.status,
    entry.path,
    entry.old_path,
    state.turn_generation or 0,
    file_state_signature(thread.repo_root, entry.path),
    diff_options_signature(),
  })
end

function M.cache_signature(session, manifest)
  local parts = {
    "combined",
    session and session.mode or "",
    diff_options_signature(),
  }
  for _, descriptor in ipairs((manifest and manifest.descriptors) or {}) do
    parts[#parts + 1] = descriptor.key or ""
    parts[#parts + 1] = descriptor.signature or ""
  end
  return stable_join(parts)
end

function M.build_explorer_manifest(session, callback)
  local explorer = session and session.explorer
  if not explorer then
    callback("combined view requires an explorer session", nil)
    return
  end
  if not explorer.git_root then
    callback("combined view does not support directory comparison yet", nil)
    return
  end

  local git = require("codediff.core.git")
  local visible_groups = explorer.visible_groups or ((config.options.explorer or {}).visible_groups)
  local status_files = collect_status_files(explorer.status_result or {}, visible_groups)
  if #status_files == 0 then
    callback(nil, { descriptors = {}, signature = "empty" })
    return
  end

  resolve_head(git, explorer.git_root, function(err_resolve, head_revision)
    if err_resolve then
      callback(err_resolve, nil)
      return
    end
    vim.schedule(function()
      local descriptors = {}
      for index, file_data in ipairs(status_files) do
        local projection = projection_for_explorer_file(explorer, file_data, head_revision)
        local descriptor = {
          index = index,
          key = projection.key,
          projection = projection,
        }
        descriptor.signature = M.projection_signature(session, descriptor)
        descriptors[#descriptors + 1] = descriptor
      end
      local manifest = { descriptors = descriptors }
      manifest.signature = M.cache_signature(session, manifest)
      callback(nil, manifest)
    end)
  end)
end

function M.build_t3code_manifest(session, callback)
  local state = session and session.t3code
  if not state then
    callback("combined view requires a t3code session", nil)
    return
  end

  local descriptors = {}
  for index, entry in ipairs(state.files or {}) do
    local descriptor = {
      index = index,
      key = entry.key or make_key("t3code", entry.path, entry.old_path),
      entry = vim.deepcopy(entry),
    }
    descriptor.signature = M.projection_signature(session, descriptor)
    descriptors[#descriptors + 1] = descriptor
  end

  local manifest = { descriptors = descriptors }
  manifest.signature = M.cache_signature(session, manifest)
  callback(nil, manifest)
end

function M.build_manifest(session, callback)
  if not session then
    callback("no codediff session", nil)
    return
  end
  if session.mode == "t3code" then
    M.build_t3code_manifest(session, callback)
  elseif session.mode == "explorer" then
    M.build_explorer_manifest(session, callback)
  else
    callback("combined view only supports explorer and t3code sessions", nil)
  end
end

function M.prepare_projection_context(session, manifest, callback)
  if not session then
    callback("no codediff session", nil)
    return
  end
  if session.mode ~= "t3code" then
    callback(nil, nil)
    return
  end

  local state = session.t3code
  if not state then
    callback("combined view requires a t3code session", nil)
    return
  end

  local entries = {}
  for _, descriptor in ipairs((manifest and manifest.descriptors) or {}) do
    if descriptor.entry then
      entries[#entries + 1] = descriptor.entry
    end
  end

  local projector = require("codediff.t3code.projector")
  local context, err = projector.prepare_combined_context(
    state.thread,
    entries,
    state.selected_turn,
    state.turn_view_mode,
    state.transport,
    state.diff_cache
  )
  callback(err, context)
end

function M.build_file_projection(session, descriptor, context, callback)
  if descriptor and descriptor.projection then
    local git = require("codediff.core.git")
    load_projection(git, vim.deepcopy(descriptor.projection), callback)
    return
  end

  local state = session and session.t3code
  if not state then
    callback("combined view requires a t3code session", nil)
    return
  end

  local projector = require("codediff.t3code.projector")
  local file, err = projector.build_combined_file(
    state.thread,
	    descriptor.entry,
	    state.selected_turn,
	    state.turn_view_mode,
    state.transport,
    state.diff_cache,
    state.combined_projection_cache,
    context
  )
  if not file then
    callback(err, nil)
    return
  end

  file.key = file.key or descriptor.key
  file.group = "t3code"
  file.git_root = state.thread.repo_root
  file.filetype = file.filetype or filetype_for(file.path)
  if file.modified_bufnr and vim.api.nvim_buf_is_valid(file.modified_bufnr) then
    file.source_bufnr = file.modified_bufnr
    file.source_path = vim.api.nvim_buf_get_name(file.modified_bufnr)
  elseif file.editable and not file.source_path and file.git_root and file.path then
    file.source_path = file.git_root .. "/" .. file.path
  end
  callback(nil, finalize_projection(file))
end

function M.build_explorer_files(session, callback)
  local explorer = session and session.explorer
  if not explorer then
    callback("combined view requires an explorer session", nil)
    return
  end
  if not explorer.git_root then
    callback("combined view does not support directory comparison yet", nil)
    return
  end

  local git = require("codediff.core.git")
  local visible_groups = explorer.visible_groups or ((config.options.explorer or {}).visible_groups)
  local status_files = collect_status_files(explorer.status_result or {}, visible_groups)
  if #status_files == 0 then
    callback(nil, {})
    return
  end

	resolve_head(git, explorer.git_root, function(_, head_revision)
		vim.schedule(function()
			local files = {}
			local pending = #status_files
			local first_err = nil

			for index, file_data in ipairs(status_files) do
				local projection = projection_for_explorer_file(explorer, file_data, head_revision)
				load_projection(git, projection, function(err, loaded)
					if err and not first_err then
						first_err = err
					end
					files[index] = loaded
					pending = pending - 1
					if pending == 0 then
						local compact = {}
						for _, item in ipairs(files) do
							if item then
								compact[#compact + 1] = item
							end
						end
						callback(first_err, compact)
					end
				end)
			end
		end)
	end)
end

function M.build_t3code_files(session, callback)
  local state = session and session.t3code
  if not state then
    callback("combined view requires a t3code session", nil)
    return
  end
  local projector = require("codediff.t3code.projector")
  local files, err = projector.build_combined_files(
    state.thread,
    state.files or {},
    state.selected_turn,
    state.turn_view_mode,
    state.transport,
    state.diff_cache,
    state.combined_projection_cache
  )
  if not files then
    callback(err, nil)
    return
  end
  for _, file in ipairs(files) do
    file.key = file.key or make_key("t3code", file.path, file.old_path)
    file.group = "t3code"
    file.git_root = state.thread.repo_root
    file.filetype = filetype_for(file.path)
    file.original_lines = sanitize_lines(file.original_lines)
    file.modified_lines = sanitize_lines(file.modified_lines)
    file.diff = M.compute_diff(file.original_lines, file.modified_lines)
    if file.modified_bufnr and vim.api.nvim_buf_is_valid(file.modified_bufnr) then
      file.source_bufnr = file.modified_bufnr
      file.source_path = vim.api.nvim_buf_get_name(file.modified_bufnr)
    end
  end
  callback(nil, files)
end

function M.build_files(session, callback)
  if not session then
    callback("no codediff session", nil)
    return
  end
  if session.mode == "t3code" then
    M.build_t3code_files(session, callback)
  elseif session.mode == "explorer" then
    M.build_explorer_files(session, callback)
  else
    callback("combined view only supports explorer and t3code sessions", nil)
  end
end

return M

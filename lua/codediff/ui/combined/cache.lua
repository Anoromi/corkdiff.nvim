local M = {}

local config = require("codediff.config")
local lifecycle = require("codediff.ui.lifecycle")
local model = require("codediff.ui.combined.model")

local function combined_config()
  return ((config.options.diff or {}).combined or {})
end

local function precompute_enabled()
  return combined_config().precompute ~= false
end

local function files_per_tick()
  return math.max(1, tonumber(combined_config().precompute_files_per_tick) or 1)
end

local function debounce_ms()
  return math.max(0, tonumber(combined_config().precompute_debounce_ms) or 120)
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

local function buffer_signature(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat({
    vim.api.nvim_buf_get_changedtick(bufnr),
    vim.fn.sha256(table.concat(lines, "\n")),
  }, "\31")
end

local function cached_file_current(file)
  if not file or not file.source_bufnr or not file.source_signature then
    return true
  end
  return buffer_signature(file.source_bufnr) == file.source_signature
end

local function ensure_cache(session)
  session.combined_cache = session.combined_cache or {
    generation = 0,
    mutable_generation = 0,
    building = false,
    ready = false,
    error = nil,
    signature = nil,
    files = nil,
    file_entries = {},
    pending_callbacks = {},
  }
  local cache = session.combined_cache
  cache.file_entries = cache.file_entries or {}
  cache.pending_callbacks = cache.pending_callbacks or {}
  cache.generation = cache.generation or 0
  cache.mutable_generation = cache.mutable_generation or 0
  return cache
end

local function finish(cache, generation, err, files)
  if cache.generation ~= generation then
    return
  end
  cache.building = false
  cache.ready = err == nil
  cache.error = err
  cache.files = err and nil or (files or {})

  local callbacks = cache.pending_callbacks or {}
  cache.pending_callbacks = {}
  for _, callback in ipairs(callbacks) do
    vim.schedule(function()
      callback(err, cache.files)
    end)
  end
end

local function start_build(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  local cache = ensure_cache(session)
  if cache.building then
    return true
  end

  local generation = cache.generation
  cache.building = true
  cache.ready = false
  cache.error = nil
  local build_started = vim.uv.hrtime()

  model.build_manifest(session, function(manifest_err, manifest)
    if cache.generation ~= generation then
      return
    end
    if manifest_err then
      finish(cache, generation, manifest_err, nil)
      return
    end

    manifest = manifest or { descriptors = {} }
    if cache.ready and cache.signature == manifest.signature and cache.files then
      cache.building = false
      finish(cache, generation, nil, cache.files)
      return
    end

    cache.signature = manifest.signature
    local descriptors = manifest.descriptors or {}
    local files = {}
    local index = 1
    local first_err = nil

    local function step()
      if cache.generation ~= generation then
        return
      end

      local processed = 0
      while processed < files_per_tick() and index <= #descriptors do
        local descriptor = descriptors[index]
        index = index + 1
        processed = processed + 1

        local entry = cache.file_entries[descriptor.key]
        if entry and entry.signature == descriptor.signature and entry.file and cached_file_current(entry.file) then
          files[#files + 1] = entry.file
        else
          local file_started = vim.uv.hrtime()
          model.build_file_projection(session, descriptor, function(file_err, file)
            profile("file " .. tostring(descriptor.key), file_started)
            if cache.generation ~= generation then
              return
            end
            if file_err and not first_err then
              first_err = file_err
            end
            if file then
              cache.file_entries[descriptor.key] = {
                signature = descriptor.signature,
                file = file,
                built_at_generation = generation,
              }
              files[#files + 1] = file
            end
            vim.schedule(step)
          end)
          return
        end
      end

      if index > #descriptors then
        profile("build", build_started)
        finish(cache, generation, first_err, files)
      else
        vim.schedule(step)
      end
    end

    step()
  end)

  return true
end

function M.invalidate(tabpage, _reason)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end
  local cache = ensure_cache(session)
  if cache.debounce_timer then
    vim.fn.timer_stop(cache.debounce_timer)
    cache.debounce_timer = nil
  end
  cache.generation = cache.generation + 1
  cache.mutable_generation = cache.mutable_generation + 1
  cache.building = false
  cache.ready = false
  cache.error = nil
  cache.signature = nil
  cache.files = nil
  cache.pending_callbacks = {}
  return true
end

function M.precompute(tabpage, opts)
  opts = opts or {}
  if not precompute_enabled() and not opts.force then
    return false
  end

  local session = lifecycle.get_session(tabpage)
  if not session or (session.mode ~= "explorer" and session.mode ~= "t3code") then
    return false
  end

  local cache = ensure_cache(session)
  if cache.ready or cache.building then
    return true
  end

  if cache.debounce_timer then
    vim.fn.timer_stop(cache.debounce_timer)
    cache.debounce_timer = nil
  end

  if opts.immediate then
    return start_build(tabpage)
  end

  cache.debounce_timer = vim.fn.timer_start(debounce_ms(), function()
    cache.debounce_timer = nil
    start_build(tabpage)
  end)
  return true
end

function M.get_ready_files(tabpage)
  local session = lifecycle.get_session(tabpage)
  local cache = session and session.combined_cache
  if cache and cache.ready and cache.files then
    return cache.files
  end
  return nil
end

function M.is_building(tabpage)
  local session = lifecycle.get_session(tabpage)
  local cache = session and session.combined_cache
  return cache and cache.building == true
end

function M.get_or_build(tabpage, callback)
  local session = lifecycle.get_session(tabpage)
  if not session then
    callback("no codediff session", nil)
    return false
  end

  local cache = ensure_cache(session)
  if cache.ready and cache.files then
    callback(nil, cache.files)
    return true
  end

  cache.pending_callbacks[#cache.pending_callbacks + 1] = callback
  start_build(tabpage)
  return false
end

return M

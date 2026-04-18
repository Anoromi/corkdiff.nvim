describe("t3code session auto-refresh", function()
  local module_names = {
    "codediff.t3code.session",
    "codediff.t3code.snapshot",
    "codediff.t3code.projector",
    "codediff.t3code.panel",
    "codediff.t3code.transport",
    "codediff.t3code.desktop",
    "codediff.ui.view",
  }
  local original_modules = {}
  local lifecycle_session = require("codediff.ui.lifecycle.session")
  local lifecycle = require("codediff.ui.lifecycle")
  local config = require("codediff.config")
  local tabpage

  local function make_thread(turn_counts)
    local checkpoints = {}
    for _, turn in ipairs(turn_counts) do
      checkpoints[#checkpoints + 1] = {
        turnCount = turn,
        checkpointRef = "refs/t3/" .. turn,
        visibleCheckpointRef = "refs/t3-visible/" .. turn,
        visibleBaseTurnCount = math.max(turn - 1, 0),
      }
    end
    return {
      id = "thread-1",
      title = "Thread 1",
      repo_root = "/repo",
      checkpoints = checkpoints,
      workspaceMutations = {},
    }
  end

  before_each(function()
    tabpage = vim.api.nvim_get_current_tabpage()
    for _, name in ipairs(module_names) do
      original_modules[name] = package.loaded[name]
      package.loaded[name] = nil
    end
    lifecycle_session.get_active_diffs()[tabpage] = {
      mode = "t3code",
      layout = "inline",
      explorer = nil,
    }
    config.options = vim.deepcopy(config.defaults)
    config.options.t3code.auto_refresh = true
    config.options.t3code.refresh_debounce_ms = 10
    config.options.t3code.reconnect_delay_ms = 10
  end)

  after_each(function()
    lifecycle_session.get_active_diffs()[tabpage] = nil
    for _, name in ipairs(module_names) do
      package.loaded[name] = original_modules[name]
    end
    config.options = vim.deepcopy(config.defaults)
  end)

  local function install_session_stubs(opts)
    opts = opts or {}
    local initial_thread = opts.initial_thread or make_thread({ 1, 2 })
    local refreshed_thread = opts.refreshed_thread or initial_thread
    local initial_snapshot = {
      updatedAt = "2026-04-14T12:00:00.000Z",
      threads = { initial_thread },
    }
    local refreshed_snapshot = {
      updatedAt = "2026-04-14T12:01:00.000Z",
      threads = { refreshed_thread },
    }
    local file_lists = opts.file_lists or {
      {
        { status = "M", path = "lua/a.lua" },
        { status = "M", path = "lua/b.lua" },
      },
      {
        { status = "M", path = "lua/a.lua" },
        { status = "M", path = "lua/b.lua" },
      },
    }
    local snapshot_load_calls = 0
    local list_files_calls = 0
    local subscribe_calls = {}
    local transport_state = {
      closed = false,
      stream_cancel_count = 0,
      subscribe_count = 0,
    }
    local updates = {}

    package.loaded["codediff.t3code.snapshot"] = {
      load = function()
        snapshot_load_calls = snapshot_load_calls + 1
        return opts.snapshot_load_results and opts.snapshot_load_results[snapshot_load_calls] or refreshed_snapshot, nil
      end,
      find_thread = function(loaded_snapshot, thread_id)
        for _, thread in ipairs(loaded_snapshot.threads or {}) do
          if thread.id == thread_id then
            return thread
          end
        end
        return nil
      end,
    }
    package.loaded["codediff.t3code.projector"] = {
      list_files = function()
        list_files_calls = list_files_calls + 1
        return vim.deepcopy(file_lists[list_files_calls] or file_lists[#file_lists]), nil
      end,
      build_live_view = function(thread, entry, selected_turn)
        return {
          mode = "t3code",
          git_root = thread.repo_root,
          original_path = entry.path,
          modified_path = entry.path,
          t3code_data = { readonly_modified = false },
          selected_turn = selected_turn,
        }, nil
      end,
      build_history_view = function(thread, entry, selected_turn)
        return {
          mode = "t3code",
          git_root = thread.repo_root,
          original_path = entry.path,
          modified_path = entry.path,
          t3code_data = { readonly_modified = true },
          selected_turn = selected_turn,
        }, nil
      end,
    }
    package.loaded["codediff.t3code.panel"] = {
      create = function(current_tabpage)
        return {
          bufnr = vim.api.nvim_create_buf(false, true),
          winid = nil,
          tabpage = current_tabpage,
          turn_regions = {},
          file_rows = {},
          is_hidden = false,
        }
      end,
      render = function(panel)
        panel.render_count = (panel.render_count or 0) + 1
      end,
      toggle_visibility = function(panel)
        panel.is_hidden = not panel.is_hidden
      end,
    }
    package.loaded["codediff.ui.view"] = {
      update = function(current_tabpage, session_config, auto_scroll)
        table.insert(updates, {
          tabpage = current_tabpage,
          session_config = session_config,
          auto_scroll = auto_scroll,
        })
        return true
      end,
    }
    package.loaded["codediff.t3code.desktop"] = {
      request_focus_app = function()
        return true
      end,
    }
    package.loaded["codediff.t3code.transport"] = {
      new_session = function()
        return {
          timeout = 10,
          closed = false,
          stream_cancel = nil,
          stream_socket = nil,
          subscribe = function(self, method, payload, handlers)
            transport_state.subscribe_count = transport_state.subscribe_count + 1
            table.insert(subscribe_calls, {
              method = method,
              payload = payload,
              handlers = handlers,
            })

            local result = opts.subscribe_results and opts.subscribe_results[transport_state.subscribe_count]
            if result == false then
              return nil, "subscribe failed"
            end

            self.stream_cancel = function()
              transport_state.stream_cancel_count = transport_state.stream_cancel_count + 1
            end
            self.stream_socket = { id = transport_state.subscribe_count }
            return true, nil
          end,
          close = function(self)
            self.closed = true
            transport_state.closed = true
            if self.stream_cancel then
              self.stream_cancel()
              self.stream_cancel = nil
            end
            self.stream_socket = nil
          end,
        }
      end,
    }

    local session = require("codediff.t3code.session")
    local panel = session.create({
      t3code_data = {
        snapshot = initial_snapshot,
        thread = initial_thread,
      },
    }, tabpage)

    local ok = vim.wait(200, function()
      return transport_state.subscribe_count >= 1
    end, 10)
    assert.is_true(ok)

    return {
      panel = panel,
      session = session,
      state = lifecycle.get_session(tabpage).t3code,
      updates = updates,
      subscribe_calls = subscribe_calls,
      transport_state = transport_state,
      snapshot_load_calls = function()
        return snapshot_load_calls
      end,
      list_files_calls = function()
        return list_files_calls
      end,
      refreshed_snapshot = refreshed_snapshot,
      refreshed_thread = refreshed_thread,
    }
  end

  it("starts the orchestration event subscription on create", function()
    local ctx = install_session_stubs()
    assert.equal(1, ctx.transport_state.subscribe_count)
    assert.equal("subscribeOrchestrationDomainEvents", ctx.subscribe_calls[1].method)
    assert.equal("connected", ctx.state.stream_status)
  end)

  it("debounces matching events and ignores other threads", function()
    local ctx = install_session_stubs()

    ctx.subscribe_calls[1].handlers.on_value({
      type = "thread.turn-diff-completed",
      payload = { threadId = "other-thread" },
    })
    vim.wait(40, function()
      return false
    end, 10)
    assert.equal(0, ctx.snapshot_load_calls())

    ctx.subscribe_calls[1].handlers.on_value({
      type = "thread.turn-diff-completed",
      payload = { threadId = "thread-1" },
    })
    ctx.subscribe_calls[1].handlers.on_value({
      type = "thread.reverted",
      payload = { threadId = "thread-1" },
    })

    local refreshed = vim.wait(200, function()
      return ctx.snapshot_load_calls() == 1
    end, 10)
    assert.is_true(refreshed)
    assert.equal(1, ctx.snapshot_load_calls())
  end)

  it("preserves file selection and falls back missing selected turns to all", function()
    local ctx = install_session_stubs({
      refreshed_thread = make_thread({ 1 }),
      file_lists = {
        {
          { status = "M", path = "lua/a.lua" },
          { status = "M", path = "lua/b.lua" },
        },
        {
          { status = "M", path = "lua/a.lua" },
          { status = "M", path = "lua/b.lua" },
        },
      },
    })

    ctx.state.current_file = {
      key = "M::::lua/b.lua",
      path = "lua/b.lua",
      status = "M",
    }
    ctx.state.current_file_key = "M::::lua/b.lua"
    ctx.state.selected_turn = 2

    ctx.subscribe_calls[1].handlers.on_value({
      type = "thread.turn-diff-completed",
      payload = { threadId = "thread-1" },
    })

    local refreshed = vim.wait(200, function()
      return ctx.snapshot_load_calls() == 1
    end, 10)
    assert.is_true(refreshed)
    assert.equal("M::::lua/b.lua", ctx.state.current_file_key)
    assert.equal("all", ctx.state.selected_turn)
  end)

  it("reconnects after stream errors and performs one catch-up refresh", function()
    local ctx = install_session_stubs()

    ctx.subscribe_calls[1].handlers.on_error("boom")

    local reconnected = vim.wait(200, function()
      return ctx.transport_state.subscribe_count == 2 and ctx.snapshot_load_calls() == 1
    end, 10)
    assert.is_true(reconnected)
    assert.equal("connected", ctx.state.stream_status)
    assert.equal(1, ctx.snapshot_load_calls())
  end)

  it("retries reconnects without background polling and cleans up timers", function()
    local ctx = install_session_stubs({
      subscribe_results = { true, false, false },
    })

    ctx.subscribe_calls[1].handlers.on_close("socket closed")

    local retried = vim.wait(250, function()
      return ctx.transport_state.subscribe_count >= 3
    end, 10)
    assert.is_true(retried)
    assert.equal(0, ctx.snapshot_load_calls())
    assert.is_nil(ctx.state.poll_timer)

    ctx.panel._cleanup_auto_refresh()
    assert.is_true(ctx.transport_state.closed)
    assert.is_true(ctx.transport_state.stream_cancel_count >= 1)
    assert.is_nil(ctx.state.reconnect_timer)
  end)
end)

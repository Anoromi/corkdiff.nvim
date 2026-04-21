describe("t3code projector", function()
  local original_git_module
  local original_projector_module

  before_each(function()
    original_git_module = package.loaded["codediff.t3code.git"]
    original_projector_module = package.loaded["codediff.t3code.projector"]
    package.loaded["codediff.t3code.projector"] = nil
  end)

  after_each(function()
    package.loaded["codediff.t3code.git"] = original_git_module
    package.loaded["codediff.t3code.projector"] = original_projector_module
  end)

  it("requests visible turn diffs using explicit visible baselines", function()
    local projector = require("codediff.t3code.projector")
    local requests = {}
    local thread = {
      id = "thread-1",
      repo_root = "/repo",
      checkpoints = {
        {
          turnId = "turn-1",
          turnCount = 1,
          checkpointRef = "refs/t3/1",
          visibleCheckpointRef = "refs/t3-visible/1",
        },
        {
          turnId = "turn-3",
          turnCount = 3,
          checkpointRef = "refs/t3/3",
          visibleCheckpointRef = "refs/t3-visible/3",
          visibleBaseTurnCount = 1,
        },
      },
    }

    local files = assert(projector.list_files(thread, 3, {
      request = function(_, method, payload)
        requests[#requests + 1] = {
          method = method,
          payload = vim.deepcopy(payload),
        }
        return {
          diff = table.concat({
            "diff --git a/lua/old.lua b/lua/new.lua",
            "similarity index 98%",
            "rename from lua/old.lua",
            "rename to lua/new.lua",
          }, "\n"),
        }
      end,
    }, {}))

    assert.same({
      {
        method = "orchestration.getTurnDiff",
        payload = {
          threadId = "thread-1",
          fromTurnCount = 1,
          toTurnCount = 3,
          includeSilent = false,
        },
      },
    }, requests)
    assert.same({
      { status = "R", old_path = "lua/old.lua", path = "lua/new.lua" },
    }, files)
  end)

  it("reads history views from visible checkpoint refs", function()
    local read_calls = {}
    package.loaded["codediff.t3code.git"] = {
      checkpoint_ref_for_turn = function()
        return "refs/t3/0"
      end,
      read_file_lines = function(_, ref, path)
        read_calls[#read_calls + 1] = { ref = ref, path = path }
        return { ref .. ":" .. path }, nil
      end,
    }

    local projector = require("codediff.t3code.projector")
    local thread = {
      id = "thread-1",
      repo_root = "/repo",
      checkpoints = {
        {
          turnId = "turn-1",
          turnCount = 1,
          checkpointRef = "refs/t3/1",
          visibleCheckpointRef = "refs/t3-visible/1",
        },
        {
          turnId = "turn-3",
          turnCount = 3,
          checkpointRef = "refs/t3/3",
          visibleCheckpointRef = "refs/t3-visible/3",
          visibleBaseTurnCount = 1,
        },
      },
    }

    local view = assert(projector.build_history_view(thread, { path = "lua/new.lua" }, 3))

    assert.same({
      { ref = "refs/t3-visible/1", path = "lua/new.lua" },
      { ref = "refs/t3-visible/3", path = "lua/new.lua" },
    }, read_calls)
    assert.equal("refs/t3-visible/1", view.original_revision)
    assert.equal("refs/t3-visible/3", view.modified_revision)
  end)

  it("follows silent mutations when projecting a live view", function()
    local temp_root = vim.fn.tempname()
    vim.fn.mkdir(temp_root, "p")
    vim.fn.writefile({ "current" }, temp_root .. "/bar.txt")

    local read_file_calls = {}
    local read_name_status_calls = {}
    package.loaded["codediff.t3code.git"] = {
      checkpoint_ref_for_turn = function()
        return "refs/t3/0"
      end,
      read_file_lines = function(_, ref, path)
        read_file_calls[#read_file_calls + 1] = { ref = ref, path = path }
        return { ref .. ":" .. path }, nil
      end,
      read_name_status = function(_, from_ref, to_ref)
        read_name_status_calls[#read_name_status_calls + 1] = {
          from_ref = from_ref,
          to_ref = to_ref,
        }
        return {
          { status = "R", old_path = "foo.txt", path = "bar.txt" },
        }, nil
      end,
      read_current_lines = function(abs_path)
        assert.equal(temp_root .. "/bar.txt", abs_path)
        return { "current" }, 17
      end,
      compute_diff = function()
        return { changes = {} }
      end,
    }

    local projector = require("codediff.t3code.projector")
    local thread = {
      id = "thread-1",
      repo_root = temp_root,
      checkpoints = {
        {
          turnId = "turn-1",
          turnCount = 1,
          checkpointRef = "refs/t3/1",
          visibleCheckpointRef = "refs/t3-visible/1",
        },
      },
      workspaceMutations = {
        {
          mutationId = "mutation-2",
          turnCount = 2,
          actualCheckpointRef = "refs/t3/2",
          visibility = "silent",
        },
      },
    }

    local view = assert(projector.build_live_view(thread, { path = "foo.txt" }, "all", nil, {}))

    assert.same({
      {
        from_ref = "refs/t3/1",
        to_ref = "refs/t3/2",
      },
    }, read_name_status_calls)
    assert.same({
      { ref = "refs/t3/0", path = "foo.txt" },
      { ref = "refs/t3-visible/1", path = "foo.txt" },
      { ref = "refs/t3/1", path = "foo.txt" },
      { ref = "refs/t3/2", path = "bar.txt" },
      { ref = "refs/t3/2", path = "bar.txt" },
    }, read_file_calls)
    assert.equal("bar.txt", view.original_path)
    assert.equal("bar.txt", view.modified_path)
  end)

  it("does not cache failed combined projections", function()
    local fail_modified = true
    package.loaded["codediff.t3code.git"] = {
      checkpoint_ref_for_turn = function()
        return "refs/t3/0"
      end,
      read_file_lines = function(_, ref, path)
        if ref == "refs/t3-visible/1" and fail_modified then
          return nil, "missing ref"
        end
        return { ref .. ":" .. path }, nil
      end,
    }

    local projector = require("codediff.t3code.projector")
    local thread = {
      id = "thread-1",
      repo_root = "/repo",
      checkpoints = {
        {
          turnId = "turn-1",
          turnCount = 1,
          checkpointRef = "refs/t3/1",
          visibleCheckpointRef = "refs/t3-visible/1",
        },
      },
    }
    local entry = { key = "foo", path = "foo.txt", status = "M" }
    local projection_cache = {}

    local failed = assert(projector.build_combined_file(thread, entry, "all", "history", nil, {}, projection_cache))
    assert.is_truthy(failed.load_error)
    assert.is_nil(next(projection_cache))

    fail_modified = false
    local succeeded = assert(projector.build_combined_file(thread, entry, "all", "history", nil, {}, projection_cache))
    assert.is_nil(succeeded.load_error)
    assert.same({ "refs/t3-visible/1:foo.txt" }, succeeded.modified_lines)
    assert.is_truthy(next(projection_cache))
  end)

  it("prepares one combined live context instead of reading checkpoint transitions per file", function()
    local temp_root = vim.fn.tempname()
    vim.fn.mkdir(temp_root, "p")
    vim.fn.writefile({ "current one" }, temp_root .. "/one.txt")
    vim.fn.writefile({ "current two" }, temp_root .. "/two.txt")

    local raw_calls = {}
    package.loaded["codediff.t3code.git"] = {
      checkpoint_ref_for_turn = function()
        return "refs/t3/0"
      end,
      read_raw_diff = function(_, from_ref, to_ref)
        raw_calls[#raw_calls + 1] = { from_ref = from_ref, to_ref = to_ref }
        if to_ref == "refs/t3-visible/1" then
          return {
            { status = "M", path = "one.txt", old_oid = "a1", new_oid = "b1" },
            { status = "M", path = "two.txt", old_oid = "a2", new_oid = "b2" },
          }, nil
        end
        return {}, nil
      end,
      index_raw_entries = function(entries)
        local index = { by_path = {}, by_old_path = {} }
        for _, entry in ipairs(entries or {}) do
          index.by_path[entry.path] = entry
          if entry.old_path then
            index.by_old_path[entry.old_path] = entry
          end
        end
        return index
      end,
      find_indexed_entry = function(index, path)
        return index and ((index.by_path or {})[path] or (index.by_old_path or {})[path]) or nil
      end,
      read_blobs = function()
        return {
          a1 = { "old one" },
          b1 = { "new one" },
          a2 = { "old two" },
          b2 = { "new two" },
        }, nil
      end,
      read_current_lines = function(abs_path)
        return vim.fn.readfile(abs_path), nil
      end,
      read_file_lines = function()
        error("read_file_lines should not be called with a prepared context")
      end,
      compute_diff = function()
        return { changes = {} }
      end,
    }

    local projector = require("codediff.t3code.projector")
    local thread = {
      id = "thread-1",
      repo_root = temp_root,
      checkpoints = {
        {
          turnCount = 1,
          checkpointRef = "refs/t3/1",
          visibleCheckpointRef = "refs/t3-visible/1",
        },
      },
      workspaceMutations = {
        {
          turnCount = 2,
          actualCheckpointRef = "refs/t3/2",
        },
      },
    }

    local files = assert(projector.build_combined_files(thread, {
      { key = "one", path = "one.txt", status = "M" },
      { key = "two", path = "two.txt", status = "M" },
    }, "all", "live", nil, {}, {}))

    assert.equal(2, #files)
    assert.same({
      { from_ref = "refs/t3/0", to_ref = "refs/t3-visible/1" },
      { from_ref = "refs/t3/1", to_ref = "refs/t3/2" },
    }, raw_calls)

    vim.fn.delete(temp_root, "rf")
  end)

  it("uses combined context to follow silent renames without per-file git show calls", function()
    local temp_root = vim.fn.tempname()
    vim.fn.mkdir(temp_root, "p")
    vim.fn.writefile({ "current bar" }, temp_root .. "/bar.txt")

    package.loaded["codediff.t3code.git"] = {
      checkpoint_ref_for_turn = function()
        return "refs/t3/0"
      end,
      read_raw_diff = function(_, _, to_ref)
        if to_ref == "refs/t3-visible/1" then
          return {
            { status = "M", path = "foo.txt", old_oid = "a", new_oid = "b" },
          }, nil
        end
        return {
          { status = "R", old_path = "foo.txt", path = "bar.txt", old_oid = "b", new_oid = "c" },
        }, nil
      end,
      index_raw_entries = function(entries)
        local index = { by_path = {}, by_old_path = {} }
        for _, entry in ipairs(entries or {}) do
          index.by_path[entry.path] = entry
          if entry.old_path then
            index.by_old_path[entry.old_path] = entry
          end
        end
        return index
      end,
      find_indexed_entry = function(index, path)
        return index and ((index.by_path or {})[path] or (index.by_old_path or {})[path]) or nil
      end,
      read_blobs = function()
        return {
          a = { "old foo" },
          b = { "new foo" },
          c = { "checkpoint bar" },
        }, nil
      end,
      read_current_lines = function(abs_path)
        assert.equal(temp_root .. "/bar.txt", abs_path)
        return { "current bar" }, nil
      end,
      read_file_lines = function()
        error("read_file_lines should not be called with a prepared context")
      end,
      compute_diff = function()
        return { changes = {} }
      end,
    }

    local projector = require("codediff.t3code.projector")
    local thread = {
      id = "thread-1",
      repo_root = temp_root,
      checkpoints = {
        {
          turnCount = 1,
          checkpointRef = "refs/t3/1",
          visibleCheckpointRef = "refs/t3-visible/1",
        },
      },
      workspaceMutations = {
        {
          turnCount = 2,
          actualCheckpointRef = "refs/t3/2",
        },
      },
    }

    local files = assert(projector.build_combined_files(thread, {
      { key = "foo", path = "foo.txt", status = "M" },
    }, "all", "live", nil, {}, {}))

    assert.equal("bar.txt", files[1].path)
    assert.same({ "current bar" }, files[1].modified_lines)
    assert.equal(temp_root .. "/bar.txt", files[1].source_path)
    assert.is_true(files[1].editable)

    vim.fn.delete(temp_root, "rf")
  end)

  it("builds add, delete, and rename history projections from combined context blobs", function()
    package.loaded["codediff.t3code.git"] = {
      checkpoint_ref_for_turn = function()
        return "refs/t3/0"
      end,
      read_raw_diff = function()
        return {
          { status = "A", path = "added.txt", old_oid = nil, new_oid = "add" },
          { status = "D", path = "deleted.txt", old_oid = "del", new_oid = nil },
          { status = "R", old_path = "old.txt", path = "new.txt", old_oid = "ren1", new_oid = "ren2" },
        }, nil
      end,
      index_raw_entries = function(entries)
        local index = { by_path = {}, by_old_path = {} }
        for _, entry in ipairs(entries or {}) do
          index.by_path[entry.path] = entry
          if entry.old_path then
            index.by_old_path[entry.old_path] = entry
          end
        end
        return index
      end,
      find_indexed_entry = function(index, path)
        return index and ((index.by_path or {})[path] or (index.by_old_path or {})[path]) or nil
      end,
      read_blobs = function()
        return {
          add = { "added" },
          del = { "deleted" },
          ren1 = { "old rename" },
          ren2 = { "new rename" },
        }, nil
      end,
      compute_diff = function()
        return { changes = {} }
      end,
    }

    local projector = require("codediff.t3code.projector")
    local thread = {
      id = "thread-1",
      repo_root = "/repo",
      checkpoints = {
        {
          turnCount = 1,
          checkpointRef = "refs/t3/1",
          visibleCheckpointRef = "refs/t3-visible/1",
        },
      },
    }

    local files = assert(projector.build_combined_files(thread, {
      { key = "add", path = "added.txt", status = "A" },
      { key = "del", path = "deleted.txt", status = "D" },
      { key = "ren", old_path = "old.txt", path = "new.txt", status = "R" },
    }, "all", "history", nil, {}, {}))

    assert.same({}, files[1].original_lines)
    assert.same({ "added" }, files[1].modified_lines)
    assert.same({ "deleted" }, files[2].original_lines)
    assert.same({}, files[2].modified_lines)
    assert.same({ "old rename" }, files[3].original_lines)
    assert.same({ "new rename" }, files[3].modified_lines)
  end)
end)

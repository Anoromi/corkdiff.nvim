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
end)

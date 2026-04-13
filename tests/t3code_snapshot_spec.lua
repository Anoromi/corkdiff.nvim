describe("t3code snapshot", function()
  it("normalizes raw t3code read model payloads", function()
    local snapshot = require("codediff.t3code.snapshot")
    local cfg = require("codediff.config")
    cfg.options.t3code.include_archived_threads = false

    local payload = {
      updatedAt = "2026-04-09T10:00:00.000Z",
      projects = {
        {
          id = "project-1",
          title = "t3code",
          workspaceRoot = "/repo",
          deletedAt = vim.NIL,
        },
      },
      threads = {
        {
          id = "thread-1",
          title = "Thread 1",
          projectId = "project-1",
          branch = "main",
          worktreePath = "/repo",
          updatedAt = "2026-04-09T10:10:00.000Z",
          archivedAt = vim.NIL,
          deletedAt = vim.NIL,
          latestTurn = { turnId = "turn-2" },
          checkpoints = {
            {
              turnId = "turn-2",
              checkpointTurnCount = 2,
              checkpointRef = "refs/t3/2",
              status = "completed",
              files = {},
              assistantMessageId = vim.NIL,
              completedAt = "2026-04-09T10:10:00.000Z",
            },
            {
              turnId = "turn-1",
              checkpointTurnCount = 1,
              checkpointRef = "refs/t3/1",
              status = "completed",
              files = {},
              assistantMessageId = vim.NIL,
              completedAt = "2026-04-09T10:05:00.000Z",
            },
          },
        },
        {
          id = "thread-archived",
          title = "Archived",
          projectId = "project-1",
          branch = "feature",
          worktreePath = "/repo",
          updatedAt = "2026-04-09T09:00:00.000Z",
          archivedAt = "2026-04-09T09:10:00.000Z",
          deletedAt = vim.NIL,
          latestTurn = vim.NIL,
          checkpoints = {},
        },
      },
    }

    local loaded = assert(snapshot.load({
      request = function(_, method)
        assert.equal("orchestration.getSnapshot", method)
        return payload
      end,
    }))

    assert.equal(1, #loaded.threads)
    assert.equal("/repo", loaded.threads[1].repo_root)
    assert.equal(1, loaded.threads[1].checkpoints[1].turnCount)
    assert.equal(2, loaded.threads[1].checkpoints[2].turnCount)
  end)
end)

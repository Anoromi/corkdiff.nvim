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
              visibleCheckpointRef = "refs/t3-visible/2",
              visibleBaseCheckpointTurnCount = 1,
              visibility = "visible",
              status = "completed",
              files = {},
              assistantMessageId = vim.NIL,
              completedAt = "2026-04-09T10:10:00.000Z",
            },
            {
              turnId = "turn-1",
              checkpointTurnCount = 1,
              checkpointRef = "refs/t3/1",
              visibleCheckpointRef = vim.NIL,
              visibleBaseCheckpointTurnCount = 0,
              visibility = vim.NIL,
              status = "completed",
              files = {},
              assistantMessageId = vim.NIL,
              completedAt = "2026-04-09T10:05:00.000Z",
            },
          },
          workspaceMutations = {
            {
              mutationId = "mutation-3",
              checkpointTurnCount = 3,
              actualCheckpointRef = "refs/t3/3",
              visibleCheckpointRef = "refs/t3-visible/2",
              visibleBaseCheckpointTurnCount = 2,
              visibility = "silent",
              files = {},
              outcome = "succeeded",
              completedAt = "2026-04-09T10:12:00.000Z",
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
    assert.equal("visible", loaded.threads[1].checkpoints[1].visibility)
    assert.equal(0, loaded.threads[1].checkpoints[1].visibleBaseTurnCount)
    assert.equal("refs/t3-visible/2", loaded.threads[1].checkpoints[2].visibleCheckpointRef)
    assert.equal(1, #loaded.threads[1].workspaceMutations)
    assert.equal(3, loaded.threads[1].workspaceMutations[1].turnCount)
    assert.equal("silent", loaded.threads[1].workspaceMutations[1].visibility)
  end)
end)

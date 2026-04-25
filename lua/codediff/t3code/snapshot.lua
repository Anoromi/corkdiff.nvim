local M = {}

local config = require("codediff.config")
local transport = require("codediff.t3code.transport")

local function is_json_null(value)
  return value == nil or value == vim.NIL
end

local function coerce_nil(value)
  if is_json_null(value) then
    return nil
  end
  return value
end

local function project_by_id(projects)
  local result = {}
  for _, project in ipairs(projects or {}) do
    if project.deletedAt == nil or project.deletedAt == vim.NIL then
      result[project.id] = {
        id = project.id,
        title = project.title,
        workspaceRoot = coerce_nil(project.workspaceRoot),
      }
    end
  end
  return result
end

local function normalize_thread(thread, projects_by_id)
  local project = projects_by_id[thread.projectId]
  local worktree_path = coerce_nil(thread.worktreePath)
  local repo_root = worktree_path or (project and project.workspaceRoot) or nil
  local checkpoints = vim.deepcopy(thread.checkpoints or {})
  local workspace_mutations = vim.deepcopy(thread.workspaceMutations or {})
  table.sort(checkpoints, function(left, right)
    return (left.checkpointTurnCount or 0) < (right.checkpointTurnCount or 0)
  end)
  table.sort(workspace_mutations, function(left, right)
    return (left.checkpointTurnCount or 0) < (right.checkpointTurnCount or 0)
  end)

  local normalized_checkpoints = {}
  for _, checkpoint in ipairs(checkpoints) do
    table.insert(normalized_checkpoints, {
      turnId = checkpoint.turnId,
      turnCount = checkpoint.checkpointTurnCount,
      checkpointRef = checkpoint.checkpointRef,
      visibleCheckpointRef = coerce_nil(checkpoint.visibleCheckpointRef),
      visibleBaseTurnCount = coerce_nil(checkpoint.visibleBaseCheckpointTurnCount),
      visibility = coerce_nil(checkpoint.visibility) or "visible",
      completedAt = checkpoint.completedAt,
      status = checkpoint.status,
      assistantMessageId = checkpoint.assistantMessageId,
      files = vim.deepcopy(checkpoint.files or {}),
    })
  end

  local normalized_workspace_mutations = {}
  for _, mutation in ipairs(workspace_mutations) do
    table.insert(normalized_workspace_mutations, {
      mutationId = mutation.mutationId,
      turnCount = mutation.checkpointTurnCount,
      actualCheckpointRef = mutation.actualCheckpointRef,
      visibleCheckpointRef = coerce_nil(mutation.visibleCheckpointRef),
      visibleBaseTurnCount = coerce_nil(mutation.visibleBaseCheckpointTurnCount),
      visibility = coerce_nil(mutation.visibility) or "silent",
      files = vim.deepcopy(mutation.files or {}),
      outcome = mutation.outcome,
      completedAt = mutation.completedAt,
    })
  end

  return {
    id = thread.id,
    title = thread.title,
    projectId = thread.projectId,
    branch = coerce_nil(thread.branch),
    forkOrigin = not is_json_null(thread.forkOrigin)
        and {
          sourceThreadId = coerce_nil(thread.forkOrigin.sourceThreadId),
          sourceTurnId = coerce_nil(thread.forkOrigin.sourceTurnId),
          sourceCheckpointTurnCount = coerce_nil(thread.forkOrigin.sourceCheckpointTurnCount),
          forkedAt = coerce_nil(thread.forkOrigin.forkedAt),
        }
      or nil,
    worktreePath = worktree_path,
    updatedAt = thread.updatedAt,
    archivedAt = coerce_nil(thread.archivedAt),
    latestTurnId = not is_json_null(thread.latestTurn) and thread.latestTurn.turnId or nil,
    repo_root = repo_root,
    project = project,
    checkpoints = normalized_checkpoints,
    workspaceMutations = normalized_workspace_mutations,
  }
end

function M.load(client)
  local payload, err
  if client then
    payload, err = client:request("orchestration.getSnapshot", {})
  else
    payload, err = transport.request_once("orchestration.getSnapshot", {})
  end
  if not payload then
    return nil, err
  end

  local include_archived = (config.options.t3code or {}).include_archived_threads
  local projects_by_id = project_by_id(payload.projects or {})
  local threads = {}
  for _, thread in ipairs(payload.threads or {}) do
    if (thread.deletedAt == nil or thread.deletedAt == vim.NIL)
      and (include_archived or not thread.archivedAt or thread.archivedAt == vim.NIL)
    then
      table.insert(threads, normalize_thread(thread, projects_by_id))
    end
  end

  table.sort(threads, function(left, right)
    return (left.updatedAt or "") > (right.updatedAt or "")
  end)

  return {
    updatedAt = payload.updatedAt,
    projects = payload.projects or {},
    threads = threads,
  }, nil
end

function M.find_thread(snapshot, thread_id)
  for _, thread in ipairs(snapshot.threads or {}) do
    if thread.id == thread_id then
      return thread
    end
  end
  return nil
end

function M.find_checkpoint(thread, turn_count)
  for _, checkpoint in ipairs(thread.checkpoints or {}) do
    if checkpoint.turnCount == turn_count then
      return checkpoint
    end
  end
  return nil
end

return M

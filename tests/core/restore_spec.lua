-- Test: restore_file with optional source revision
-- Validates that restore_file correctly restores files from index (default)
-- and from specific revisions when source is provided

local git = require("codediff.core.git")

-- Helper to run sync git commands in a directory
local function git_sync(args, cwd)
  local cmd = vim.list_extend({ "git" }, args)
  local result = vim.fn.system(cmd, nil)
  if vim.v.shell_error ~= 0 then
    error("git command failed: " .. table.concat(cmd, " ") .. "\n" .. result)
  end
  return vim.trim(result)
end

-- Helper to create a temp git repo with history
local function create_test_repo()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")

  local old_dir = vim.fn.getcwd()
  vim.fn.chdir(temp_dir)

  git_sync({ "init" }, temp_dir)
  git_sync({ "config", "user.email", "test@test.com" }, temp_dir)
  git_sync({ "config", "user.name", "Test" }, temp_dir)

  -- Commit 1: initial content
  vim.fn.writefile({ "version 1" }, temp_dir .. "/file.txt")
  git_sync({ "add", "file.txt" }, temp_dir)
  git_sync({ "commit", "-m", "commit 1" }, temp_dir)
  local commit1 = git_sync({ "rev-parse", "HEAD" }, temp_dir)

  -- Commit 2: updated content
  vim.fn.writefile({ "version 2" }, temp_dir .. "/file.txt")
  git_sync({ "add", "file.txt" }, temp_dir)
  git_sync({ "commit", "-m", "commit 2" }, temp_dir)
  local commit2 = git_sync({ "rev-parse", "HEAD" }, temp_dir)

  -- Working tree change (unstaged)
  vim.fn.writefile({ "version 3 working" }, temp_dir .. "/file.txt")

  vim.fn.chdir(old_dir)

  return {
    dir = temp_dir,
    commit1 = commit1,
    commit2 = commit2,
    cleanup = function()
      vim.fn.delete(temp_dir, "rf")
    end,
  }
end

describe("restore_file", function()
  it("restores from index when no source given (default behavior)", function()
    local repo = create_test_repo()

    -- file.txt is "version 3 working" in working tree, "version 2" in index
    local done = false
    local restore_err = nil

    git.restore_file(repo.dir, "file.txt", function(err)
      restore_err = err
      done = true
    end)

    vim.wait(3000, function() return done end)
    assert.is_true(done, "Callback should be invoked")
    assert.is_nil(restore_err, "Should not error: " .. tostring(restore_err))

    -- File should now match index (commit 2 = "version 2")
    local content = vim.fn.readfile(repo.dir .. "/file.txt")
    assert.are.same({ "version 2" }, content, "Should restore to index (version 2)")

    repo.cleanup()
  end)

  it("restores from specific commit when source is provided", function()
    local repo = create_test_repo()

    -- file.txt is "version 3 working", restore to commit1 which has "version 1"
    local done = false
    local restore_err = nil

    git.restore_file(repo.dir, "file.txt", repo.commit1, function(err)
      restore_err = err
      done = true
    end)

    vim.wait(3000, function() return done end)
    assert.is_true(done, "Callback should be invoked")
    assert.is_nil(restore_err, "Should not error: " .. tostring(restore_err))

    local content = vim.fn.readfile(repo.dir .. "/file.txt")
    assert.are.same({ "version 1" }, content, "Should restore to commit1 (version 1)")

    repo.cleanup()
  end)

  it("restores from HEAD when source is HEAD", function()
    local repo = create_test_repo()

    local done = false
    local restore_err = nil

    git.restore_file(repo.dir, "file.txt", "HEAD", function(err)
      restore_err = err
      done = true
    end)

    vim.wait(3000, function() return done end)
    assert.is_true(done, "Callback should be invoked")
    assert.is_nil(restore_err, "Should not error: " .. tostring(restore_err))

    local content = vim.fn.readfile(repo.dir .. "/file.txt")
    assert.are.same({ "version 2" }, content, "Should restore to HEAD (version 2)")

    repo.cleanup()
  end)

  it("restores from HEAD~1 when source is HEAD~1", function()
    local repo = create_test_repo()

    local done = false
    local restore_err = nil

    git.restore_file(repo.dir, "file.txt", "HEAD~1", function(err)
      restore_err = err
      done = true
    end)

    vim.wait(3000, function() return done end)
    assert.is_true(done, "Callback should be invoked")
    assert.is_nil(restore_err, "Should not error: " .. tostring(restore_err))

    local content = vim.fn.readfile(repo.dir .. "/file.txt")
    assert.are.same({ "version 1" }, content, "Should restore to HEAD~1 (version 1)")

    repo.cleanup()
  end)

  it("passes nil source correctly (backward compat with 3-arg call)", function()
    local repo = create_test_repo()

    -- Old-style 3-arg call: restore_file(root, path, callback)
    local done = false
    local restore_err = nil

    git.restore_file(repo.dir, "file.txt", function(err)
      restore_err = err
      done = true
    end)

    vim.wait(3000, function() return done end)
    assert.is_true(done, "Callback should be invoked")
    assert.is_nil(restore_err, "Should not error: " .. tostring(restore_err))

    local content = vim.fn.readfile(repo.dir .. "/file.txt")
    assert.are.same({ "version 2" }, content, "3-arg call should restore from index")

    repo.cleanup()
  end)

  it("errors on invalid source revision", function()
    local repo = create_test_repo()

    local done = false
    local restore_err = nil

    git.restore_file(repo.dir, "file.txt", "nonexistent-rev-12345", function(err)
      restore_err = err
      done = true
    end)

    vim.wait(3000, function() return done end)
    assert.is_true(done, "Callback should be invoked")
    assert.is_not_nil(restore_err, "Should error on invalid revision")

    repo.cleanup()
  end)
end)

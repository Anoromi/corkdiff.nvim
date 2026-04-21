describe("t3code git helpers", function()
  local h = dofile("tests/helpers.lua")

  it("loads current file contents from an existing unloaded buffer", function()
    local git = require("codediff.t3code.git")
    local path = vim.fn.tempname()
    vim.fn.writefile({ "alpha", "beta" }, path)

    local bufnr = vim.fn.bufadd(path)
    assert.is_false(vim.api.nvim_buf_is_loaded(bufnr))

    local lines, returned_bufnr = git.read_current_lines(path)

    assert.equal(bufnr, returned_bufnr)
    assert.same({ "alpha", "beta" }, lines)
    assert.is_true(vim.api.nvim_buf_is_loaded(bufnr))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    vim.fn.delete(path)
  end)

  it("can read current file contents without loading an unloaded buffer", function()
    local git = require("codediff.t3code.git")
    local path = vim.fn.tempname()
    vim.fn.writefile({ "alpha", "beta" }, path)

    local bufnr = vim.fn.bufadd(path)
    assert.is_false(vim.api.nvim_buf_is_loaded(bufnr))

    local lines, returned_bufnr = git.read_current_lines(path, { load_unloaded_buffer = false })

    assert.is_nil(returned_bufnr)
    assert.same({ "alpha", "beta" }, lines)
    assert.is_false(vim.api.nvim_buf_is_loaded(bufnr))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    vim.fn.delete(path)
  end)

  it("parses raw diffs with blob ids for modifications, additions, deletions, and renames", function()
    local git = require("codediff.t3code.git")
    local repo = h.create_temp_git_repo()

    repo.write_file("modified.txt", { "old" })
    repo.write_file("deleted.txt", { "delete me" })
    repo.write_file("space old.txt", { "rename me" })
    repo.git("add .")
    repo.git("commit -m initial")

    repo.write_file("modified.txt", { "new" })
    repo.write_file("added.txt", { "added" })
    vim.fn.delete(repo.path("deleted.txt"))
    repo.git("mv " .. vim.fn.shellescape("space old.txt") .. " " .. vim.fn.shellescape("space new.txt"))
    repo.git("add -A")
    repo.git("commit -m changes")

    local entries = assert(git.read_raw_diff(repo.dir, "HEAD~1", "HEAD"))
    local indexed = git.index_raw_entries(entries)

    assert.equal("M", indexed.by_path["modified.txt"].status)
    assert.is_truthy(indexed.by_path["modified.txt"].old_oid)
    assert.is_truthy(indexed.by_path["modified.txt"].new_oid)
    assert.equal("A", indexed.by_path["added.txt"].status)
    assert.is_nil(indexed.by_path["added.txt"].old_oid)
    assert.is_truthy(indexed.by_path["added.txt"].new_oid)
    assert.equal("D", indexed.by_path["deleted.txt"].status)
    assert.is_truthy(indexed.by_path["deleted.txt"].old_oid)
    assert.is_nil(indexed.by_path["deleted.txt"].new_oid)
    assert.equal("R", indexed.by_path["space new.txt"].status)
    assert.equal("space old.txt", indexed.by_path["space new.txt"].old_path)
    assert.equal(indexed.by_path["space new.txt"], indexed.by_old_path["space old.txt"])

    local blobs = assert(git.read_blobs(repo.dir, {
      indexed.by_path["modified.txt"].new_oid,
      indexed.by_path["added.txt"].new_oid,
    }))
    assert.same({ "new" }, blobs[indexed.by_path["modified.txt"].new_oid])
    assert.same({ "added" }, blobs[indexed.by_path["added.txt"].new_oid])

    repo.cleanup()
  end)
end)

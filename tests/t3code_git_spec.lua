describe("t3code git helpers", function()
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
end)

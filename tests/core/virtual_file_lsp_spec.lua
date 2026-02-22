-- Test: Verify virtual buffers don't fire FileType autocmd (prevents LSP attachment)
-- This test simulates what LSP plugins like eslint/terraform-ls do:
-- they listen for FileType events and call vim.lsp.start() to attach.
-- Setting filetype on virtual buffers causes these plugins to attach,
-- sending textDocument/didOpen with codediff:// URI which crashes servers.
--
-- This test should FAIL if vim.bo[buf].filetype is set on virtual buffers
-- and PASS when TreeSitter is started directly without setting filetype.

local virtual_file = require("codediff.core.virtual_file")

describe("Virtual buffer LSP prevention", function()
  it("prevents LSP attachment while keeping TreeSitter active", function()
    -- Ensure virtual file autocmds are registered (plugin file may not be sourced in test subprocess)
    virtual_file.setup()
    -- Create a temp git repo
    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    vim.fn.system("git -C " .. temp_dir .. " init")
    vim.fn.system("git -C " .. temp_dir .. " config user.email 'test@test.com'")
    vim.fn.system("git -C " .. temp_dir .. " config user.name 'Test'")

    local f = io.open(temp_dir .. "/app.js", "w")
    f:write("const x = 1;\nconsole.log(x);\n")
    f:close()
    vim.fn.system("git -C " .. temp_dir .. " add .")
    vim.fn.system("git -C " .. temp_dir .. " commit -m 'initial'")

    -- Setup a mock LSP that mimics eslint/terraform-ls behavior:
    -- Listen for FileType and call vim.lsp.start() to attach.
    -- Before the fix: FileType fires → LSP attaches to virtual buffer.
    -- After the fix: FileType never fires → LSP never sees the buffer.
    local mock_lsp_attach_attempts = {}
    local mock_autocmd_id = vim.api.nvim_create_autocmd("FileType", {
      pattern = { "javascript" },
      callback = function(args)
        local bufname = vim.api.nvim_buf_get_name(args.buf)
        table.insert(mock_lsp_attach_attempts, {
          buf = args.buf,
          bufname = bufname,
          is_virtual = bufname:match("^codediff://") ~= nil,
        })
        -- Mimic what real LSP plugins do: call vim.lsp.start()
        -- Use 'cat' as a trivial LSP server (accepts stdin, does nothing)
        pcall(vim.lsp.start, {
          name = "mock-eslint",
          cmd = { "cat" },
          root_dir = temp_dir,
        })
      end,
    })

    -- Create a virtual buffer (this is what CodeDiff does internally)
    local commit = vim.fn.system("git -C " .. temp_dir .. " rev-parse HEAD"):gsub("%s+", "")
    local url = "codediff:///" .. temp_dir .. "///" .. commit .. "/app.js"
    vim.cmd("edit " .. vim.fn.fnameescape(url))
    local buf = vim.api.nvim_get_current_buf()

    -- Wait for async content loading
    vim.wait(3000, function()
      if not vim.api.nvim_buf_is_valid(buf) then return false end
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      return #lines > 0 and lines[1] ~= ""
    end)

    -- 1. Mock LSP should NOT have been triggered for virtual buffers
    local virtual_attempts = vim.tbl_filter(
      function(a) return a.is_virtual end,
      mock_lsp_attach_attempts
    )
    assert.are.equal(0, #virtual_attempts,
      "Mock LSP should NOT have been triggered for virtual buffers (FileType should not fire)")

    -- 2. No LSP clients should be attached to the virtual buffer
    local clients = vim.lsp.get_clients({ bufnr = buf })
    assert.are.equal(0, #clients,
      "No LSP clients should be attached to virtual buffer")

    -- 3. filetype should be empty (prevents FileType autocmd)
    assert.are.equal("", vim.bo[buf].filetype,
      "filetype should be empty on virtual buffer")

    -- 4. TreeSitter should be active if parser is available
    -- (CI environments may not have all TreeSitter parsers installed)
    local has_parser = pcall(vim.treesitter.language.inspect, "javascript")
    if has_parser then
      local ok, parser = pcall(vim.treesitter.get_parser, buf)
      assert.is_true(ok and parser ~= nil,
        "TreeSitter parser should be active on virtual buffer")
    end

    -- 5. buftype should be nowrite
    assert.are.equal("nowrite", vim.bo[buf].buftype,
      "buftype should be nowrite")

    -- Cleanup: stop any mock LSP clients that might have started
    for _, client in ipairs(vim.lsp.get_clients({ name = "mock-eslint" })) do
      pcall(client.stop, client)
    end
    vim.api.nvim_del_autocmd(mock_autocmd_id)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.fn.delete(temp_dir, "rf")
  end)
end)

-- Module loading tests for history submodules
-- Validates that require() wiring works correctly after _set_*_module removal

-- Ensure nui.nvim is on package.path (plenary subprocess may have different CWD)
local nui_dir = vim.fn.stdpath("data") .. "/nui.nvim"
if vim.fn.isdirectory(nui_dir) == 1 then
  nui_dir = nui_dir:gsub("\\", "/")
  if not package.path:find(nui_dir, 1, true) then
    package.path = package.path .. ";" .. nui_dir .. "/lua/?.lua;" .. nui_dir .. "/lua/?/init.lua"
  end
end

describe("History submodules", function()
  describe("module loading", function()
    it("loads refresh module", function()
      local ok, mod = pcall(require, "codediff.ui.history.refresh")
      assert.is_true(ok, "Failed to require codediff.ui.history.refresh")
      assert.is_not_nil(mod)
    end)

    it("loads render module", function()
      local ok, mod = pcall(require, "codediff.ui.history.render")
      assert.is_true(ok, "Failed to require codediff.ui.history.render")
      assert.is_not_nil(mod)
    end)

    it("loads init facade", function()
      local ok, mod = pcall(require, "codediff.ui.history")
      assert.is_true(ok, "Failed to require codediff.ui.history")
      assert.is_not_nil(mod)
    end)
  end)

  describe("public API", function()
    it("refresh exports expected functions", function()
      local mod = require("codediff.ui.history.refresh")
      assert.is_function(mod.setup_auto_refresh)
      assert.is_function(mod.refresh)
    end)

    it("render exports expected functions", function()
      local mod = require("codediff.ui.history.render")
      assert.is_function(mod.build_tree_nodes)
      assert.is_function(mod.create)
      assert.is_function(mod.get_all_files)
      assert.is_function(mod.navigate_next)
      assert.is_function(mod.navigate_prev)
      assert.is_function(mod.get_all_commits)
      assert.is_function(mod.navigate_next_commit)
      assert.is_function(mod.navigate_prev_commit)
      assert.is_function(mod.toggle_visibility)
    end)
  end)
end)

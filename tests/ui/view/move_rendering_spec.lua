-- Test: Move rendering in side-by-side mode
-- Verifies CodeDiffLineMove highlights, sign column symbols, and number_hl_group
-- on moved code blocks detected by the diff engine.

local view = require("codediff.ui.view")
local diff = require("codediff.core.diff")
local highlights = require("codediff.ui.highlights")
local lifecycle = require("codediff.ui.lifecycle")

local ns_highlight = highlights.ns_highlight

-- OS-aware temp path helper
local function get_temp_path(filename)
  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local temp_dir = is_windows and (vim.fn.getenv("TEMP") or "C:\\Windows\\Temp") or "/tmp"
  local sep = is_windows and "\\" or "/"
  return temp_dir .. sep .. filename
end

-- Swap test pair: two functions swap positions
local orig = { "function foo()", "  return 1", "end", "", "function bar()", "  return 2", "end" }
local mod = { "function bar()", "  return 2", "end", "", "function foo()", "  return 1", "end" }

-- Create a standalone side-by-side diff view from two temp files
local function create_move_view(original_lines, modified_lines, suffix, setup_opts)
  require("codediff").setup(setup_opts or { diff = { compute_moves = true, layout = "side-by-side" } })
  highlights.setup()

  local left_path = get_temp_path("move_render_left_" .. suffix .. ".txt")
  local right_path = get_temp_path("move_render_right_" .. suffix .. ".txt")
  vim.fn.writefile(original_lines, left_path)
  vim.fn.writefile(modified_lines, right_path)

  local session_config = {
    mode = "standalone",
    git_root = nil,
    original_path = left_path,
    modified_path = right_path,
    original_revision = nil,
    modified_revision = nil,
  }

  view.create(session_config)
  vim.cmd("redraw")
  vim.wait(500)

  local tabpage = vim.api.nvim_get_current_tabpage()
  return tabpage, left_path, right_path
end

-- Collect extmarks with details from a buffer in ns_highlight
local function get_extmarks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns_highlight, 0, -1, { details = true })
end

-- Return set of 0-indexed lines that carry a specific hl_group
local function lines_with_hl(bufnr, hl_group)
  local marks = get_extmarks(bufnr)
  local set = {}
  for _, m in ipairs(marks) do
    local details = m[4]
    if details.hl_group == hl_group then
      set[m[2]] = true -- m[2] is 0-indexed line
    end
  end
  return set
end

-- Return map of 0-indexed line -> sign_text for extmarks that have sign_text
local function signs_on_buf(bufnr)
  local marks = get_extmarks(bufnr)
  local map = {}
  for _, m in ipairs(marks) do
    local details = m[4]
    if details.sign_text then
      -- Neovim pads sign_text to 2 chars; trim trailing whitespace for comparison
      map[m[2]] = { text = vim.trim(details.sign_text), hl = details.sign_hl_group }
    end
  end
  return map
end

-- Return map of 0-indexed line -> number_hl_group
local function number_hl_on_buf(bufnr)
  local marks = get_extmarks(bufnr)
  local map = {}
  for _, m in ipairs(marks) do
    local details = m[4]
    if details.number_hl_group then
      map[m[2]] = details.number_hl_group
    end
  end
  return map
end

describe("Move rendering (side-by-side)", function()
  after_each(function()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
  end)

  -- Pre-compute expected move ranges from the diff engine so tests stay in
  -- sync with whatever the C library decides.
  local move_result = diff.compute_diff(orig, mod, { compute_moves = true })
  assert(#move_result.moves > 0, "precondition: diff engine must detect at least one move")

  local move = move_result.moves[1]
  -- Ranges are 1-based, end is exclusive
  local orig_first = move.original.start_line
  local orig_last = move.original.end_line - 1
  local mod_first = move.modified.start_line
  local mod_last = move.modified.end_line - 1

  -- Helper: set of 0-indexed lines that should be moved on original side
  local orig_moved_lines_0 = {}
  for l = orig_first, orig_last do
    orig_moved_lines_0[l - 1] = true
  end

  local mod_moved_lines_0 = {}
  for l = mod_first, mod_last do
    mod_moved_lines_0[l - 1] = true
  end

  -- ──────────────────────────────────────────────────────────────────────────
  -- Test 1: CodeDiffLineMove highlights on correct lines
  -- ──────────────────────────────────────────────────────────────────────────
  it("places CodeDiffLineMove highlights only on moved lines", function()
    local tabpage, lp, rp = create_move_view(orig, mod, "hl")

    local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
    assert(orig_buf and mod_buf, "buffers must exist")

    -- Original side
    local hl_orig = lines_with_hl(orig_buf, "CodeDiffLineMove")
    for line_0 = 0, #orig - 1 do
      if orig_moved_lines_0[line_0] then
        assert.is_true(hl_orig[line_0] ~= nil, "original line " .. (line_0 + 1) .. " should have CodeDiffLineMove")
      else
        assert.is_nil(hl_orig[line_0], "original line " .. (line_0 + 1) .. " should NOT have CodeDiffLineMove")
      end
    end

    -- Modified side
    local hl_mod = lines_with_hl(mod_buf, "CodeDiffLineMove")
    for line_0 = 0, #mod - 1 do
      if mod_moved_lines_0[line_0] then
        assert.is_true(hl_mod[line_0] ~= nil, "modified line " .. (line_0 + 1) .. " should have CodeDiffLineMove")
      else
        assert.is_nil(hl_mod[line_0], "modified line " .. (line_0 + 1) .. " should NOT have CodeDiffLineMove")
      end
    end

    vim.fn.delete(lp)
    vim.fn.delete(rp)
  end)

  -- ──────────────────────────────────────────────────────────────────────────
  -- Test 2: Sign column symbols correct on original side
  -- ──────────────────────────────────────────────────────────────────────────
  it("sets correct sign column symbols on original side", function()
    local tabpage, lp, rp = create_move_view(orig, mod, "sign_orig")

    local orig_buf = lifecycle.get_buffers(tabpage)
    assert(orig_buf, "original buffer must exist")

    local signs = signs_on_buf(orig_buf)

    local block_len = orig_last - orig_first + 1

    for line = orig_first, orig_last do
      local line_0 = line - 1
      assert(signs[line_0], "sign expected on original line " .. line)

      local expected_sign
      if block_len == 1 then
        expected_sign = "─"
      elseif line == orig_first then
        expected_sign = "┌"
      elseif line == orig_last then
        expected_sign = "└"
      else
        expected_sign = "│"
      end

      assert.equal(expected_sign, signs[line_0].text,
        "original line " .. line .. " sign mismatch")
      assert.equal("CodeDiffMoveTo", signs[line_0].hl,
        "original line " .. line .. " sign_hl_group mismatch")
    end

    vim.fn.delete(lp)
    vim.fn.delete(rp)
  end)

  -- ──────────────────────────────────────────────────────────────────────────
  -- Test 3: Sign column symbols correct on modified side
  -- ──────────────────────────────────────────────────────────────────────────
  it("sets correct sign column symbols on modified side", function()
    local tabpage, lp, rp = create_move_view(orig, mod, "sign_mod")

    local _, mod_buf = lifecycle.get_buffers(tabpage)
    assert(mod_buf, "modified buffer must exist")

    local signs = signs_on_buf(mod_buf)

    local block_len = mod_last - mod_first + 1

    for line = mod_first, mod_last do
      local line_0 = line - 1
      assert(signs[line_0], "sign expected on modified line " .. line)

      local expected_sign
      if block_len == 1 then
        expected_sign = "─"
      elseif line == mod_first then
        expected_sign = "┌"
      elseif line == mod_last then
        expected_sign = "└"
      else
        expected_sign = "│"
      end

      assert.equal(expected_sign, signs[line_0].text,
        "modified line " .. line .. " sign mismatch")
      assert.equal("CodeDiffMoveTo", signs[line_0].hl,
        "modified line " .. line .. " sign_hl_group mismatch")
    end

    vim.fn.delete(lp)
    vim.fn.delete(rp)
  end)

  -- ──────────────────────────────────────────────────────────────────────────
  -- Test 4: number_hl_group is CodeDiffMoveTo on moved lines
  -- ──────────────────────────────────────────────────────────────────────────
  it("sets number_hl_group to CodeDiffMoveTo on moved lines", function()
    local tabpage, lp, rp = create_move_view(orig, mod, "numhl")

    local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
    assert(orig_buf and mod_buf, "buffers must exist")

    -- Original side
    local nhl_orig = number_hl_on_buf(orig_buf)
    for line = orig_first, orig_last do
      assert.equal("CodeDiffMoveTo", nhl_orig[line - 1],
        "original line " .. line .. " should have number_hl_group = CodeDiffMoveTo")
    end

    -- Modified side
    local nhl_mod = number_hl_on_buf(mod_buf)
    for line = mod_first, mod_last do
      assert.equal("CodeDiffMoveTo", nhl_mod[line - 1],
        "modified line " .. line .. " should have number_hl_group = CodeDiffMoveTo")
    end

    vim.fn.delete(lp)
    vim.fn.delete(rp)
  end)

  -- ──────────────────────────────────────────────────────────────────────────
  -- Test 5: No move rendering when compute_moves = false
  -- ──────────────────────────────────────────────────────────────────────────
  it("produces no CodeDiffLineMove extmarks when compute_moves is false", function()
    local tabpage, lp, rp = create_move_view(orig, mod, "nomove", {
      diff = { compute_moves = false, layout = "side-by-side" },
    })

    local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
    assert(orig_buf and mod_buf, "buffers must exist")

    local hl_orig = lines_with_hl(orig_buf, "CodeDiffLineMove")
    local hl_mod = lines_with_hl(mod_buf, "CodeDiffLineMove")

    assert.equal(0, vim.tbl_count(hl_orig), "original should have no CodeDiffLineMove extmarks")
    assert.equal(0, vim.tbl_count(hl_mod), "modified should have no CodeDiffLineMove extmarks")

    vim.fn.delete(lp)
    vim.fn.delete(rp)
  end)
end)

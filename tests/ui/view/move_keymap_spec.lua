-- Tests for the `gm` align_move keymap
-- Validates keymap binding, alignment behavior, scrollbind restore, and edge cases

local view = require("codediff.ui.view")
local diff_module = require("codediff.core.diff")
local highlights = require("codediff.ui.highlights")
local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")

-- Content with a moved block: alpha block moves from top to bottom
-- The diff engine needs ≥5 contiguous moved lines to detect a move.
local function make_original_lines()
  return {
    "alpha_1",
    "alpha_2",
    "alpha_3",
    "alpha_4",
    "alpha_5",
    "unchanged_1",
    "unchanged_2",
    "unchanged_3",
    "beta_1",
    "beta_2",
    "beta_3",
    "beta_4",
    "beta_5",
  }
end

local function make_modified_lines()
  return {
    "unchanged_1",
    "unchanged_2",
    "unchanged_3",
    "beta_1",
    "beta_2",
    "beta_3",
    "beta_4",
    "beta_5",
    "alpha_1",
    "alpha_2",
    "alpha_3",
    "alpha_4",
    "alpha_5",
  }
end

--- Write temp files and return paths (OS-aware via vim.fn.tempname)
local function write_temp_files(original_lines, modified_lines)
  local left_path = vim.fn.tempname() .. "_move_left.txt"
  local right_path = vim.fn.tempname() .. "_move_right.txt"
  vim.fn.writefile(original_lines, left_path)
  vim.fn.writefile(modified_lines, right_path)
  return left_path, right_path
end

--- Wait for session to be fully ready with move data
local function wait_for_session_with_moves(tabpage, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local session
  local ok = vim.wait(timeout_ms, function()
    session = lifecycle.get_session(tabpage)
    return session
      and session.stored_diff_result
      and session.stored_diff_result.moves
      and #session.stored_diff_result.moves > 0
  end, 50)
  return ok, session
end

--- Wait for session to be ready (may or may not have moves)
local function wait_for_session(tabpage, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local session
  local ok = vim.wait(timeout_ms, function()
    session = lifecycle.get_session(tabpage)
    return session and session.stored_diff_result ~= nil
  end, 50)
  return ok, session
end

--- Check whether buffer has a normal-mode keymap with the given lhs
local function buf_has_keymap(bufnr, lhs)
  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  for _, m in ipairs(maps) do
    if m.lhs == lhs then
      return true
    end
  end
  return false
end

describe("gm align_move keymap", function()
  local left_path, right_path

  after_each(function()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    if left_path then pcall(vim.fn.delete, left_path) end
    if right_path then pcall(vim.fn.delete, right_path) end
    left_path, right_path = nil, nil
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 1. gm is bound when compute_moves = true
  -- ──────────────────────────────────────────────────────────────
  it("gm keymap is bound when compute_moves=true", function()
    require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
    highlights.setup()

    left_path, right_path = write_temp_files(make_original_lines(), make_modified_lines())

    view.create({
      mode = "standalone",
      git_root = nil,
      original_path = left_path,
      modified_path = right_path,
      original_revision = nil,
      modified_revision = nil,
    })

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, session = wait_for_session_with_moves(tabpage)
    assert.is_true(ok, "Session should be ready with moves")

    -- gm should be set on both diff buffers
    assert.is_true(buf_has_keymap(session.original_bufnr, "gm"), "gm should be bound on original buffer")
    assert.is_true(buf_has_keymap(session.modified_bufnr, "gm"), "gm should be bound on modified buffer")
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 2. gm is NOT bound when compute_moves = false
  -- ──────────────────────────────────────────────────────────────
  it("gm is not bound when compute_moves=false", function()
    require("codediff").setup({ diff = { compute_moves = false, layout = "side-by-side" } })
    highlights.setup()

    left_path, right_path = write_temp_files(make_original_lines(), make_modified_lines())

    view.create({
      mode = "standalone",
      git_root = nil,
      original_path = left_path,
      modified_path = right_path,
      original_revision = nil,
      modified_revision = nil,
    })

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, session = wait_for_session(tabpage)
    assert.is_true(ok, "Session should be ready")

    assert.is_false(buf_has_keymap(session.original_bufnr, "gm"), "gm should NOT be bound on original buffer")
    assert.is_false(buf_has_keymap(session.modified_bufnr, "gm"), "gm should NOT be bound on modified buffer")
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 3. gm aligns moved blocks at same winline()
  -- ──────────────────────────────────────────────────────────────
  it("gm aligns moved blocks at same winline()", function()
    require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
    highlights.setup()

    left_path, right_path = write_temp_files(make_original_lines(), make_modified_lines())

    view.create({
      mode = "standalone",
      git_root = nil,
      original_path = left_path,
      modified_path = right_path,
      original_revision = nil,
      modified_revision = nil,
    })

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, session = wait_for_session_with_moves(tabpage)
    assert.is_true(ok, "Session should be ready with moves")

    local moves = session.stored_diff_result.moves
    assert.is_true(#moves >= 1, "Should have at least one move")

    local move = moves[1]
    -- move.original = { start_line = 1, end_line = 6 }  (alpha block in original)
    -- move.modified = { start_line = 9, end_line = 14 } (alpha block in modified)

    -- Focus original window and position cursor on the first line of the moved block
    vim.api.nvim_set_current_win(session.original_win)
    vim.api.nvim_win_set_cursor(session.original_win, { move.original.start_line, 0 })
    vim.cmd("normal! zz")
    vim.cmd("redraw")

    -- Read the visual row of the moved block's first line before alignment
    local orig_visual_before = vim.api.nvim_win_call(session.original_win, function()
      vim.api.nvim_win_set_cursor(session.original_win, { move.original.start_line, 0 })
      return vim.fn.winline()
    end)

    -- Trigger the gm keymap action
    local gm_keys = vim.api.nvim_replace_termcodes("gm", true, false, true)
    vim.api.nvim_feedkeys(gm_keys, "x", false)
    vim.cmd("redraw")

    -- After gm: read visual row of orig first line again (it may have been repositioned)
    local orig_visual_after = vim.api.nvim_win_call(session.original_win, function()
      return vim.fn.winline()
    end)

    -- Read visual row of paired block's first line on modified side
    local mod_visual = vim.api.nvim_win_call(session.modified_win, function()
      vim.api.nvim_win_set_cursor(session.modified_win, { move.modified.start_line, 0 })
      return vim.fn.winline()
    end)

    -- The paired block on the modified side should be aligned to the same visual row
    assert.are.equal(orig_visual_after, mod_visual,
      string.format("Moved block visual rows should match: original winline=%d, modified winline=%d",
        orig_visual_after, mod_visual))
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 4. Restore scrollbind on cursor leave
  -- ──────────────────────────────────────────────────────────────
  it("restores scrollbind when cursor leaves moved block", function()
    require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
    highlights.setup()

    left_path, right_path = write_temp_files(make_original_lines(), make_modified_lines())

    view.create({
      mode = "standalone",
      git_root = nil,
      original_path = left_path,
      modified_path = right_path,
      original_revision = nil,
      modified_revision = nil,
    })

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, session = wait_for_session_with_moves(tabpage)
    assert.is_true(ok, "Session should be ready with moves")

    local moves = session.stored_diff_result.moves
    local move = moves[1]

    -- Note scrollbind state before gm
    local orig_sb_before = vim.wo[session.original_win].scrollbind
    local mod_sb_before = vim.wo[session.modified_win].scrollbind

    -- Focus original window, position on moved block, trigger gm
    vim.api.nvim_set_current_win(session.original_win)
    vim.api.nvim_win_set_cursor(session.original_win, { move.original.start_line, 0 })
    vim.cmd("redraw")

    local gm_keys = vim.api.nvim_replace_termcodes("gm", true, false, true)
    vim.api.nvim_feedkeys(gm_keys, "x", false)
    vim.cmd("redraw")

    -- Scrollbind should be disabled while aligned
    assert.is_false(vim.wo[session.original_win].scrollbind, "scrollbind should be disabled during alignment")
    assert.is_false(vim.wo[session.modified_win].scrollbind, "scrollbind should be disabled during alignment")

    -- Move cursor OUT of the moved block range using feedkeys so CursorMoved fires.
    -- Note: CursorMoved does not fire in headless mode, so we manually trigger it
    -- via doautocmd after repositioning the cursor.
    -- After gm the cursor sits at move.original.start_line. Jump to end of buffer
    -- which is guaranteed to be outside the moved block.
    vim.api.nvim_win_set_cursor(session.original_win, { vim.api.nvim_buf_line_count(session.original_bufnr), 0 })
    vim.cmd("doautocmd CursorMoved")
    vim.cmd("redraw")

    -- Scrollbind should be restored to its original state
    assert.are.equal(orig_sb_before, vim.wo[session.original_win].scrollbind,
      "scrollbind should be restored on original window")
    assert.are.equal(mod_sb_before, vim.wo[session.modified_win].scrollbind,
      "scrollbind should be restored on modified window")
  end)

  -- ──────────────────────────────────────────────────────────────
  -- 5. gm shows message (no error) when not on a moved block
  -- ──────────────────────────────────────────────────────────────
  it("gm shows message when not on a moved block", function()
    require("codediff").setup({ diff = { compute_moves = true, layout = "side-by-side" } })
    highlights.setup()

    left_path, right_path = write_temp_files(make_original_lines(), make_modified_lines())

    view.create({
      mode = "standalone",
      git_root = nil,
      original_path = left_path,
      modified_path = right_path,
      original_revision = nil,
      modified_revision = nil,
    })

    local tabpage = vim.api.nvim_get_current_tabpage()
    local ok, session = wait_for_session_with_moves(tabpage)
    assert.is_true(ok, "Session should be ready with moves")

    local moves = session.stored_diff_result.moves
    local move = moves[1]

    -- Position cursor on a line that is NOT inside any moved block
    -- The unchanged lines start at line 6 in original (after alpha block ends at line 6 exclusive)
    local non_moved_line = move.original.end_line -- end_line is exclusive, so this line is outside
    local line_count = vim.api.nvim_buf_line_count(session.original_bufnr)
    if non_moved_line > line_count then
      non_moved_line = line_count
    end

    vim.api.nvim_set_current_win(session.original_win)
    vim.api.nvim_win_set_cursor(session.original_win, { non_moved_line, 0 })
    vim.cmd("redraw")

    -- Trigger gm - should not error, just show a notification
    local succeeded = pcall(function()
      local gm_keys = vim.api.nvim_replace_termcodes("gm", true, false, true)
      vim.api.nvim_feedkeys(gm_keys, "x", false)
      vim.cmd("redraw")
    end)

    assert.is_true(succeeded, "gm should not error when not on a moved block")

    -- Scrollbind should remain unchanged (no alignment happened)
    -- Just verify windows are still valid and no crash occurred
    assert.is_true(vim.api.nvim_win_is_valid(session.original_win), "original window should still be valid")
    assert.is_true(vim.api.nvim_win_is_valid(session.modified_win), "modified window should still be valid")
  end)
end)

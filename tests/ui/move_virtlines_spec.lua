-- Test: move annotation virt_lines and filler alignment
-- Verifies that moved code blocks produce correct ⇄ annotations
-- and matching filler virt_lines on the opposite side.

local core = require("codediff.ui.core")
local diff_module = require("codediff.core.diff")
local highlights = require("codediff.ui.highlights")
local ns_highlight = require("codediff.ui.highlights").ns_highlight
local ns_filler = require("codediff.ui.highlights").ns_filler

-- Content that reliably produces one detected move.
-- The "setup()" block (orig L2-7) moves to mod L7-12.
local original_lines = {
  "line 1: header section",
  "line 2: function setup()",
  "line 3:   local x = 1",
  "line 4:   local y = 2",
  "line 5:   return x + y",
  "line 6: end",
  "line 7: ",
  "line 8: function cleanup()",
  "line 9:   local a = 10",
  "line 10:   local b = 20",
  "line 11:   return a - b",
  "line 12: end",
  "line 13: footer section",
}

local modified_lines = {
  "line 1: header section",
  "line 8: function cleanup()",
  "line 9:   local a = 10",
  "line 10:   local b = 20",
  "line 11:   return a - b",
  "line 12: end",
  "line 7: ",
  "line 2: function setup()",
  "line 3:   local x = 1",
  "line 4:   local y = 2",
  "line 5:   return x + y",
  "line 6: end",
  "line 13: footer section",
}

--- Create scratch buffers, fill them, compute diff with compute_moves, render.
--- @return number left_buf, number right_buf, table lines_diff
local function setup_move_buffers()
  local left_buf = vim.api.nvim_create_buf(false, true)
  local right_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original_lines)
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, modified_lines)

  local lines_diff = diff_module.compute_diff(original_lines, modified_lines, { compute_moves = true })
  core.render_diff(left_buf, right_buf, original_lines, modified_lines, lines_diff)

  return left_buf, right_buf, lines_diff
end

--- Collect all extmarks that carry virt_lines from a given buffer/namespace.
--- @return table[] Each entry: { row = 0-indexed line, above = bool, texts = {string,...} }
local function collect_virt_line_marks(bufnr, ns)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local result = {}
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.virt_lines then
      local texts = {}
      for _, vl in ipairs(details.virt_lines) do
        -- vl is a list of {text, hl_group} chunks
        for _, chunk in ipairs(vl) do
          table.insert(texts, chunk[1])
        end
      end
      table.insert(result, {
        row = mark[2],
        above = details.virt_lines_above or false,
        texts = texts,
        num_virt_lines = #details.virt_lines,
      })
    end
  end
  return result
end

describe("Move annotation virt_lines", function()
  before_each(function()
    require("codediff").setup({ diff = { layout = "side-by-side", compute_moves = true } })
    highlights.setup()
  end)

  after_each(function()
    -- Close extra tabs that tests may have opened
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
  end)

  -- Precondition: compute_diff with compute_moves produces at least one move.
  it("detects at least one move in the test data", function()
    local lines_diff = diff_module.compute_diff(original_lines, modified_lines, { compute_moves = true })
    assert.is_true(#lines_diff.moves >= 1, "Should detect at least 1 move")
  end)

  -- 1. Annotation virt_line exists above moved block on original (left) side.
  it("places annotation virt_line above moved block on original side", function()
    local left_buf, right_buf, lines_diff = setup_move_buffers()
    local move = lines_diff.moves[1]

    local vl_marks = collect_virt_line_marks(left_buf, ns_highlight)

    -- Find the annotation containing "⇄ moved"
    local found = nil
    for _, m in ipairs(vl_marks) do
      for _, t in ipairs(m.texts) do
        if t:find("⇄ moved") then
          found = m
          break
        end
      end
      if found then break end
    end

    assert.is_not_nil(found, "Should find an annotation virt_line with '⇄ moved' on left buffer")

    -- Anchor should be move.original.start_line - 1 (0-indexed)
    local expected_row = math.max(move.original.start_line - 1, 0)
    assert.are.equal(expected_row, found.row,
      string.format("Annotation should be anchored at row %d (0-indexed), got %d", expected_row, found.row))

    -- Must be above the line
    assert.is_true(found.above, "Annotation virt_line should have virt_lines_above = true")

    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  -- 2. Annotation virt_line exists above moved block on modified (right) side.
  it("places annotation virt_line above moved block on modified side", function()
    local left_buf, right_buf, lines_diff = setup_move_buffers()
    local move = lines_diff.moves[1]

    local vl_marks = collect_virt_line_marks(right_buf, ns_highlight)

    local found = nil
    for _, m in ipairs(vl_marks) do
      for _, t in ipairs(m.texts) do
        if t:find("⇄ moved") then
          found = m
          break
        end
      end
      if found then break end
    end

    assert.is_not_nil(found, "Should find an annotation virt_line with '⇄ moved' on right buffer")

    local expected_row = math.max(move.modified.start_line - 1, 0)
    assert.are.equal(expected_row, found.row,
      string.format("Annotation should be anchored at row %d (0-indexed), got %d", expected_row, found.row))

    assert.is_true(found.above, "Annotation virt_line should have virt_lines_above = true")

    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  -- 3. Annotation label contains the line range mapping.
  it("annotation label matches the expected L-range pattern", function()
    local left_buf, right_buf, lines_diff = setup_move_buffers()
    local move = lines_diff.moves[1]

    -- Check both sides
    for _, bufnr in ipairs({ left_buf, right_buf }) do
      local vl_marks = collect_virt_line_marks(bufnr, ns_highlight)

      for _, m in ipairs(vl_marks) do
        for _, t in ipairs(m.texts) do
          if t:find("⇄ moved") then
            -- Pattern: "⇄ moved: L<d>-<d> → L<d>-<d>"
            local pat = "⇄ moved: L%d+-%d+ → L%d+-%d+"
            assert.is_truthy(t:match(pat),
              string.format("Label %q should match pattern %q", t, pat))
          end
        end
      end
    end

    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  -- 4. Filler virt_line on opposite side for each annotation.
  --    The annotation above the original block produces a filler on the modified
  --    side (and vice-versa). Move fillers use ns_filler, virt_lines_above=true,
  --    and contain the "╱" pattern.
  it("creates filler virt_line on the opposite side for each annotation", function()
    local left_buf, right_buf, lines_diff = setup_move_buffers()

    -- Filler on modified (right) side matching the original annotation
    local right_fillers = collect_virt_line_marks(right_buf, ns_filler)
    local right_move_fillers = {}
    for _, m in ipairs(right_fillers) do
      if m.above then
        for _, t in ipairs(m.texts) do
          if t:find("╱") then
            table.insert(right_move_fillers, m)
            break
          end
        end
      end
    end
    assert.is_true(#right_move_fillers >= 1,
      "Should have at least 1 above-filler virt_line on right buffer (opposite of original annotation)")

    -- Filler on original (left) side matching the modified annotation
    local left_fillers = collect_virt_line_marks(left_buf, ns_filler)
    local left_move_fillers = {}
    for _, m in ipairs(left_fillers) do
      if m.above then
        for _, t in ipairs(m.texts) do
          if t:find("╱") then
            table.insert(left_move_fillers, m)
            break
          end
        end
      end
    end
    assert.is_true(#left_move_fillers >= 1,
      "Should have at least 1 above-filler virt_line on left buffer (opposite of modified annotation)")

    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)

  -- 5. Each move produces exactly 2 annotation virt_lines + 2 filler virt_lines = 4 total.
  it("produces 2 annotations and 2 fillers for a single move", function()
    local left_buf, right_buf, lines_diff = setup_move_buffers()
    assert.are.equal(1, #lines_diff.moves, "Test data should have exactly 1 move")

    -- Count annotation virt_lines (ns_highlight containing "⇄ moved")
    local annotation_count = 0
    for _, bufnr in ipairs({ left_buf, right_buf }) do
      local vl_marks = collect_virt_line_marks(bufnr, ns_highlight)
      for _, m in ipairs(vl_marks) do
        for _, t in ipairs(m.texts) do
          if t:find("⇄ moved") then
            annotation_count = annotation_count + 1
            break -- count each mark only once
          end
        end
      end
    end
    assert.are.equal(2, annotation_count,
      string.format("Expected 2 annotation virt_lines (one per side), got %d", annotation_count))

    -- Count move filler virt_lines (ns_filler with virt_lines_above=true and "╱")
    local filler_count = 0
    for _, bufnr in ipairs({ left_buf, right_buf }) do
      local vl_marks = collect_virt_line_marks(bufnr, ns_filler)
      for _, m in ipairs(vl_marks) do
        if m.above then
          for _, t in ipairs(m.texts) do
            if t:find("╱") then
              filler_count = filler_count + 1
              break
            end
          end
        end
      end
    end
    assert.are.equal(2, filler_count,
      string.format("Expected 2 move filler virt_lines (one per side), got %d", filler_count))

    -- Total = 4
    assert.are.equal(4, annotation_count + filler_count,
      string.format("Expected 4 total move virt_line extmarks, got %d", annotation_count + filler_count))

    vim.api.nvim_buf_delete(left_buf, { force = true })
    vim.api.nvim_buf_delete(right_buf, { force = true })
  end)
end)

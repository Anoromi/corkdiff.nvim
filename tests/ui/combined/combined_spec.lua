local h = dofile("tests/helpers.lua")

h.ensure_plugin_loaded()

local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local combined_cache = require("codediff.ui.combined.cache")

local function wait_for_combined(tabpage)
  local ok = vim.wait(10000, function()
    local session = lifecycle.get_session(tabpage)
    return session
      and session.layout == "combined"
      and session.combined
      and session.combined.files
      and #session.combined.files > 0
      and session.modified_bufnr
      and vim.api.nvim_buf_is_valid(session.modified_bufnr)
  end, 100)
  assert.is_true(ok, "combined session should render")
  return lifecycle.get_session(tabpage)
end

local function open_combined_explorer(repo)
  local git = require("codediff.core.git")
  local status_result
  local status_err
  git.get_status(repo.dir, function(err, result)
    status_err = err
    status_result = result
  end)
  assert.is_true(vim.wait(10000, function()
    return status_err ~= nil or status_result ~= nil
  end, 100), "git status should finish")
  assert.is_nil(status_err)

  view.create({
    mode = "explorer",
    git_root = repo.dir,
    original_path = "",
    modified_path = "",
    layout = "combined",
    explorer_data = {
      status_result = status_result,
    },
  })

  local tabpage = vim.api.nvim_get_current_tabpage()
  return tabpage, wait_for_combined(tabpage)
end

local function open_explorer(repo, layout_name)
  local git = require("codediff.core.git")
  local status_result
  local status_err
  git.get_status(repo.dir, function(err, result)
    status_err = err
    status_result = result
  end)
  assert.is_true(vim.wait(10000, function()
    return status_err ~= nil or status_result ~= nil
  end, 100), "git status should finish")
  assert.is_nil(status_err)

  view.create({
    mode = "explorer",
    git_root = repo.dir,
    original_path = "",
    modified_path = "",
    layout = layout_name or "inline",
    explorer_data = {
      status_result = status_result,
    },
  })

  return vim.api.nvim_get_current_tabpage()
end

local function wait_for_cache(tabpage)
  local ok = vim.wait(10000, function()
    local files = combined_cache.get_ready_files(tabpage)
    return files and #files > 0
  end, 100)
  assert.is_true(ok, "combined cache should be ready")
  return combined_cache.get_ready_files(tabpage)
end

local function wait_for_file_view(tabpage, path, layout_name)
  local ok = vim.wait(10000, function()
    local session = lifecycle.get_session(tabpage)
    local explorer = lifecycle.get_explorer(tabpage)
    return session
      and session.layout == layout_name
      and session.layout ~= "combined"
      and explorer
      and explorer.current_selection
      and explorer.current_selection.path == path
  end, 100)
  assert.is_true(ok, "file view should focus " .. path)
  return lifecycle.get_session(tabpage)
end

describe("combined view", function()
  local repo

  before_each(function()
    require("codediff").setup({
      diff = {
        layout = "side-by-side",
        combined = {
          initial_view = "changes",
          context_lines = 1,
          auto_rebuild_structural_edits = true,
        },
      },
    })
    repo = h.create_temp_git_repo()
		repo.write_file("one.txt", {
			"one a",
			"one b",
			"one c",
			"one d",
			"one e",
			"one f",
			"one g",
			"one h",
		})
    repo.write_file("two.txt", {
      "two a",
      "two b",
      "two c",
    })
    repo.git("add one.txt two.txt")
    repo.git("commit -m initial")
		repo.write_file("one.txt", {
			"one a",
			"ONE B",
			"one c",
			"one d",
			"one e",
			"one f",
			"one g",
			"one h changed",
		})
    repo.write_file("two.txt", {
      "two a",
      "TWO B",
      "two c",
    })
  end)

  after_each(function()
    h.close_extra_tabs()
    if repo then
      repo.cleanup()
    end
    require("codediff").setup({ diff = { layout = "side-by-side" } })
  end)

  it("renders all explorer files in one changes buffer", function()
    local _, session = open_combined_explorer(repo)
    local content = h.get_buffer_content(session.modified_bufnr)

    h.assert_contains(content, "@@ one.txt M unstaged @@")
    h.assert_contains(content, "@@ two.txt M unstaged @@")
    h.assert_contains(content, "ONE B")
    h.assert_contains(content, "TWO B")
    h.assert_contains(content, "... unchanged lines omitted ...")
    assert.equal("changes", session.combined.view)
  end)

  it("renders deletion-only hunks as real deleted rows", function()
    repo.write_file("delete-only.txt", {
      "keep",
      "remove me",
      "also remove",
      "tail",
    })
    repo.git("add delete-only.txt")
    repo.git("commit -m add-delete-only")
    repo.write_file("delete-only.txt", {
      "keep",
      "tail",
    })

    local _, session = open_combined_explorer(repo)
    local content = h.get_buffer_content(session.modified_bufnr)
    h.assert_contains(content, "@@ delete-only.txt M unstaged @@")
    h.assert_contains(content, "remove me")
    h.assert_contains(content, "also remove")
    assert.is_nil(content:find("(no modified-side lines)", 1, true))

    local deleted_row
    for row, map in pairs(session.combined.line_map or {}) do
      if map.type == "deleted_content" and map.original_line == 2 then
        deleted_row = row
        break
      end
    end
    assert.equal("number", type(deleted_row), "deleted row should be represented in line_map")

    local deleted_hunk
    for _, hunk in ipairs(session.combined.hunks or {}) do
      if hunk.path == "delete-only.txt" then
        deleted_hunk = hunk
        break
      end
    end
    assert.is_truthy(deleted_hunk, "combined state should expose deletion hunk navigation")
    assert.equal(deleted_row, deleted_hunk.line)

    local found_delete_hl = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(session.modified_bufnr, require("codediff.ui.combined.render").ns, 0, -1, { details = true })) do
      local row0 = mark[2]
      local details = mark[4] or {}
      if row0 == deleted_row - 1 and details.hl_group == "CodeDiffLineDelete" then
        found_delete_hl = true
        break
      end
    end
    assert.is_true(found_delete_hl, "deleted rows should receive CodeDiffLineDelete")
  end)

  it("shows projection load errors instead of empty modified-side placeholders", function()
    local render = require("codediff.ui.combined.render")
    local bufnr = vim.api.nvim_create_buf(false, true)
    local state = render.render(bufnr, {
      {
        path = "bad.lua",
        status = "M",
        group = "t3code",
        original_lines = {},
        modified_lines = {},
        diff = { changes = {}, moves = {} },
        load_error = "missing ref",
      },
    }, { view = "changes" })
    local content = h.get_buffer_content(bufnr)

    h.assert_contains(content, "Failed to load modified content: missing ref")
    assert.is_nil(content:find("(no modified-side lines)", 1, true))
    assert.equal("error", state.line_map[2].type)
  end)

  it("toggles between changes and full file content", function()
    local tabpage, session = open_combined_explorer(repo)
    assert.equal("changes", session.combined.view)

    assert.is_true(view.toggle_combined_view(tabpage))
    session = wait_for_combined(tabpage)
    assert.equal("full", session.combined.view)

		local content = h.get_buffer_content(session.modified_bufnr)
		h.assert_contains(content, "one d")
		h.assert_contains(content, "one h changed")
  end)

  it("writes full-mode edits back to multiple source files", function()
    local tabpage, session = open_combined_explorer(repo)
    assert.is_true(view.toggle_combined_view(tabpage))
    session = wait_for_combined(tabpage)

    local lines = h.get_buffer_lines(session.modified_bufnr)
    for i, line in ipairs(lines) do
      if line == "ONE B" then
        lines[i] = "ONE B saved"
      elseif line == "TWO B" then
        lines[i] = "TWO B saved"
      end
    end
    vim.api.nvim_buf_set_lines(session.modified_bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_call(session.modified_bufnr, function()
      vim.cmd("write")
    end)

		assert.same({
			"one a",
			"ONE B saved",
			"one c",
			"one d",
			"one e",
			"one f",
			"one g",
			"one h changed",
		}, vim.fn.readfile(repo.path("one.txt")))
    assert.same({ "two a", "TWO B saved", "two c" }, vim.fn.readfile(repo.path("two.txt")))
  end)

	  it("toggles combined from an existing explorer session and restores inline", function()
	    require("codediff").setup({ diff = { layout = "inline" } })
	    local tabpage, session = open_combined_explorer(repo)
    assert.equal("combined", session.layout)
    assert.is_true(view.toggle_combined(tabpage))
    assert.is_true(vim.wait(10000, function()
      local current = lifecycle.get_session(tabpage)
      return current and current.layout == "inline"
	    end, 100), "combined toggle should restore inline")
	  end)

  it("leaves combined view using the file under the combined cursor", function()
    require("codediff").setup({ diff = { layout = "inline" } })
    local tabpage = open_explorer(repo, "inline")
    wait_for_cache(tabpage)

    assert.is_true(view.toggle_combined(tabpage))
    local session = wait_for_combined(tabpage)

    assert.is_true(require("codediff.ui.combined.navigation").jump_to_file(tabpage, {
      path = "two.txt",
      group = "unstaged",
    }))

    assert.is_true(view.toggle_combined(tabpage))
    local current = wait_for_file_view(tabpage, "two.txt", "inline")
    h.assert_contains(h.get_buffer_content(current.modified_bufnr), "TWO B")
  end)

  it("re-enters combined view at the current single-file selection", function()
    require("codediff").setup({ diff = { layout = "inline" } })
    local tabpage = open_explorer(repo, "inline")
    wait_for_cache(tabpage)

    assert.is_true(view.toggle_combined(tabpage))
    wait_for_combined(tabpage)

    assert.is_true(require("codediff.ui.combined.navigation").jump_to_file(tabpage, {
      path = "two.txt",
      group = "unstaged",
    }))

    assert.is_true(view.toggle_combined(tabpage))
    wait_for_file_view(tabpage, "two.txt", "inline")

    assert.is_true(view.toggle_combined(tabpage))
    wait_for_combined(tabpage)

    local file = require("codediff.ui.combined.navigation").current_file(tabpage)
    assert.is_truthy(file)
    assert.equal("two.txt", file.path)
  end)

  it("uses precomputed explorer files when toggling into combined view", function()
    local model = require("codediff.ui.combined.model")
    local original_compute = model.compute_diff
    local compute_count = 0
    model.compute_diff = function(...)
      compute_count = compute_count + 1
      return original_compute(...)
    end

    local tabpage = open_explorer(repo, "inline")
    wait_for_cache(tabpage)
    compute_count = 0

    assert.is_true(view.toggle_combined(tabpage))
    wait_for_combined(tabpage)
    assert.equal(0, compute_count, "cached combined toggle should not recompute per-file diffs")

    model.compute_diff = original_compute
  end)

  it("rebuilds only stale explorer projections after a working file changes", function()
    local model = require("codediff.ui.combined.model")
    local original_compute = model.compute_diff
    local compute_count = 0
    model.compute_diff = function(...)
      compute_count = compute_count + 1
      return original_compute(...)
    end

    local tabpage = open_explorer(repo, "inline")
    local cached_files = wait_for_cache(tabpage)
    compute_count = 0

    local one_buf
    for _, file in ipairs(cached_files) do
      if file.path == "one.txt" then
        one_buf = file.source_bufnr
      end
    end
    assert.is_not_nil(one_buf, "one.txt should have a source buffer from precompute")
    vim.bo[one_buf].modifiable = true
    vim.api.nvim_buf_set_lines(one_buf, 0, -1, false, {
      "one a",
      "ONE B stale",
      "one c",
      "one d",
      "one e",
      "one f",
      "one g",
      "one h changed",
    })

    assert.is_true(combined_cache.invalidate(tabpage, "test"))
    assert.is_nil(combined_cache.get_ready_files(tabpage))
    combined_cache.precompute(tabpage, { immediate = true })
    wait_for_cache(tabpage)
    assert.equal(1, compute_count, "only the changed file projection should be recomputed")

    model.compute_diff = original_compute
  end)

  it("reuses cached diffs and syntax when toggling combined view mode", function()
    local model = require("codediff.ui.combined.model")
    local inline = require("codediff.ui.inline")
    local original_compute = model.compute_diff
    local original_syntax = inline.compute_syntax_highlights
    local compute_count = 0
    local syntax_count = 0

    model.compute_diff = function(...)
      compute_count = compute_count + 1
      return original_compute(...)
    end
    inline.compute_syntax_highlights = function(...)
      syntax_count = syntax_count + 1
      return original_syntax(...)
    end

    local tabpage, session = open_combined_explorer(repo)
    assert.equal("changes", session.combined.view)
    compute_count = 0
    syntax_count = 0

    assert.is_true(view.toggle_combined_view(tabpage))
    session = wait_for_combined(tabpage)
    assert.equal("full", session.combined.view)
    assert.equal(0, compute_count, "view-mode toggle should not recompute diffs")
    assert.equal(0, syntax_count, "view-mode toggle should reuse syntax highlights")

    model.compute_diff = original_compute
    inline.compute_syntax_highlights = original_syntax
  end)

	  it("jump_to_file prefers keyed matches over path fallbacks", function()
    local render = require("codediff.ui.combined.render")
    local navigation = require("codediff.ui.combined.navigation")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local win = vim.api.nvim_get_current_win()
    local original_buf = vim.api.nvim_create_buf(false, true)
    local combined_buf = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_win_set_buf(win, combined_buf)
    lifecycle.create_session(
      tabpage,
      "t3code",
      repo.dir,
      "",
      "",
      nil,
      nil,
      original_buf,
      combined_buf,
      win,
      win,
      { changes = {}, moves = {} },
      nil
    )
    lifecycle.update_layout(tabpage, "combined")

    local session = lifecycle.get_session(tabpage)
    session.combined = render.render(combined_buf, {
      {
        key = "first",
        path = "same.txt",
        old_path = "same-old.txt",
        status = "M",
        group = "t3code",
        original_lines = { "one" },
        modified_lines = { "ONE" },
        diff = { changes = {}, moves = {} },
      },
      {
        key = "second",
        path = "same.txt",
        old_path = "same-old.txt",
        status = "M",
        group = "t3code",
        original_lines = { "two" },
        modified_lines = { "TWO" },
        diff = { changes = {}, moves = {} },
      },
    }, { view = "full" })

    assert.is_true(navigation.jump_to_file(tabpage, {
      key = "second",
      path = "same.txt",
      group = "t3code",
      old_path = "same-old.txt",
    }))

    local file = navigation.current_file(tabpage)
	    assert.is_truthy(file)
	    assert.equal("second", file.key)
	  end)

  it("does not precompute t3code combined files from inline layout unless forced", function()
    local model = require("codediff.ui.combined.model")
    local original_build_manifest = model.build_manifest
    local original_prepare_context = model.prepare_projection_context
    local build_count = 0

    model.build_manifest = function(_, callback)
      build_count = build_count + 1
      callback(nil, { descriptors = {}, signature = "empty" })
    end
    model.prepare_projection_context = function(_, _, callback)
      callback(nil, nil)
    end

    local tabpage = vim.api.nvim_get_current_tabpage()
    local win = vim.api.nvim_get_current_win()
    local original_buf = vim.api.nvim_create_buf(false, true)
    local modified_buf = vim.api.nvim_create_buf(false, true)
    lifecycle.create_session(
      tabpage,
      "t3code",
      repo.dir,
      "",
      "",
      nil,
      nil,
      original_buf,
      modified_buf,
      win,
      win,
      { changes = {}, moves = {} },
      nil
    )
    lifecycle.update_layout(tabpage, "inline")

    assert.is_false(combined_cache.precompute(tabpage, { immediate = true }))
    assert.equal(0, build_count)

    assert.is_true(combined_cache.precompute(tabpage, { immediate = true, force = true }))
    assert.equal(1, build_count)

    model.build_manifest = original_build_manifest
    model.prepare_projection_context = original_prepare_context
  end)

  it("mirrors diagnostics with one diagnostic lookup per source buffer", function()
    local render = require("codediff.ui.combined.render")
    local combined_buf = vim.api.nvim_create_buf(false, true)
    local source_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(combined_buf, 0, -1, false, { "one", "two" })
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "one", "two" })

    local original_get = vim.diagnostic.get
    local get_count = 0
    vim.diagnostic.get = function(bufnr, opts)
      get_count = get_count + 1
      assert.equal(source_buf, bufnr)
      assert.is_nil(opts)
      return {
        {
          lnum = 0,
          col = 0,
          end_col = 3,
          severity = vim.diagnostic.severity.ERROR,
          message = "first",
        },
        {
          lnum = 1,
          col = 0,
          end_col = 3,
          severity = vim.diagnostic.severity.WARN,
          message = "second",
        },
      }
    end

    render.mirror_diagnostics(combined_buf, {
      line_map = {
        [1] = { type = "content", source_bufnr = source_buf, modified_line = 1 },
        [2] = { type = "content", source_bufnr = source_buf, modified_line = 2 },
      },
    })

    assert.equal(1, get_count)
    vim.diagnostic.get = original_get
  end)
		end)

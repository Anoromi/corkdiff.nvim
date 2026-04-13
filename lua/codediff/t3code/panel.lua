local M = {}

local Split = require("codediff.ui.lib.split")
local config = require("codediff.config")
local render = require("codediff.t3code.render")

local function panel_config()
  return config.options.t3code or {}
end

function M.render(panel)
  render.render(panel)
end

function M.create(tabpage, state)
  local cfg = panel_config()
  local split = Split({
    relative = "editor",
    position = cfg.position or "left",
    size = (cfg.position or "left") == "bottom" and (cfg.height or 15) or (cfg.width or 40),
    buf_options = {
      modifiable = false,
      readonly = true,
      filetype = "codediff-t3code",
    },
    win_options = {
      number = false,
      relativenumber = false,
      cursorline = true,
      wrap = false,
      signcolumn = "no",
      foldcolumn = "0",
      winhighlight = "CursorLine:CodeDiffT3codeSelection",
    },
  })

  split:mount()
  pcall(vim.api.nvim_buf_set_name, split.bufnr, "CodeDiff T3code [" .. tabpage .. "]")

  local panel = {
    split = split,
    bufnr = split.bufnr,
    winid = split.winid,
    tabpage = tabpage,
    thread = state.thread,
    turn_options = state.turn_options,
    selected_turn = state.selected_turn,
    turn_view_mode = state.turn_view_mode,
    files = state.files,
    current_file_key = state.current_file_key,
    turn_regions = {},
    file_rows = {},
    is_hidden = false,
  }

  M.render(panel)
  return panel
end

function M.toggle_visibility(panel)
  if not panel or not panel.split then
    return
  end
  if panel.is_hidden then
    panel.split:show()
    panel.is_hidden = false
    panel.winid = panel.split.winid
  else
    panel.split:hide()
    panel.is_hidden = true
    panel.winid = nil
  end
end

return M

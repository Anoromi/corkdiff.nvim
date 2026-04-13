-- Node creation and formatting for explorer
-- Handles file/directory nodes, icons, status symbols, and tree structure
local M = {}

local Tree = require("codediff.ui.lib.tree")
local Line = require("codediff.ui.lib.line")
local config = require("codediff.config")

-- Merge artifact patterns (created by git mergetool)
local MERGE_ARTIFACT_PATTERNS = {
  "%.orig$", -- file.orig
  "%.BACKUP%.", -- file.BACKUP.xxxxx
  "%.BASE%.", -- file.BASE.xxxxx
  "%.LOCAL%.", -- file.LOCAL.xxxxx
  "%.REMOTE%.", -- file.REMOTE.xxxxx
  "_BACKUP_%d+%.", -- file_BACKUP_xxxxx.ext
  "_BASE_%d+%.", -- file_BASE_xxxxx.ext
  "_LOCAL_%d+%.", -- file_LOCAL_xxxxx.ext
  "_REMOTE_%d+%.", -- file_REMOTE_xxxxx.ext
  "_BACKUP_%d+$", -- file_BACKUP_xxxxx
  "_BASE_%d+$", -- file_BASE_xxxxx
  "_LOCAL_%d+$", -- file_LOCAL_xxxxx
  "_REMOTE_%d+$", -- file_REMOTE_xxxxx
}

-- Status symbols and colors
local STATUS_SYMBOLS = {
  M = { symbol = "M", color = "CodeDiffStatusModified" },
  A = { symbol = "A", color = "CodeDiffStatusAdded" },
  D = { symbol = "D", color = "CodeDiffStatusDeleted" },
  R = { symbol = "R", color = "CodeDiffStatusRenamed" },
  ["??"] = { symbol = "??", color = "CodeDiffStatusUntracked" },
  ["!"] = { symbol = "!", color = "CodeDiffStatusConflict" },
}

-- Indent marker characters (neo-tree style)
local INDENT_MARKERS = {
  edge = "│", -- Vertical line for non-last items
  item = "├", -- Branch for non-last items
  last = "└", -- Branch for last item
  none = " ", -- Space when parent was last item
}

-- Check if a file path matches merge artifact patterns
local function is_merge_artifact(path)
  for _, pattern in ipairs(MERGE_ARTIFACT_PATTERNS) do
    if path:match(pattern) then
      return true
    end
  end
  return false
end

-- Filter out merge artifacts from file list
function M.filter_merge_artifacts(files)
  if not config.options.diff.hide_merge_artifacts then
    return files
  end

  local filtered = {}
  for _, file in ipairs(files) do
    if not is_merge_artifact(file.path) then
      table.insert(filtered, file)
    end
  end
  return filtered
end

-- File icons (basic fallback)
function M.get_file_icon(path)
  local has_devicons, devicons = pcall(require, "nvim-web-devicons")
  if has_devicons then
    local icon, color = devicons.get_icon(path, nil, { default = true })
    return icon or "", color
  end
  return "", nil
end

function M.get_status_display(status)
  local info = STATUS_SYMBOLS[status]
  if info then
    return info.symbol, info.color
  end
  return status or "", "Normal"
end

function M.get_selected_highlight(base_hl_name, selection_hl_name)
  local selection_hl = selection_hl_name or "CodeDiffExplorerSelected"
  local sel_hl = vim.api.nvim_get_hl(0, { name = selection_hl, link = false })
  local selected_bg = sel_hl.bg
  if not selected_bg then
    return base_hl_name or "Normal"
  end

  local resolved_base = base_hl_name or "Normal"
  local combined_name = (selection_hl .. "_" .. resolved_base):gsub("[^%w]", "_")
  local base_hl = vim.api.nvim_get_hl(0, { name = resolved_base, link = false })

  vim.api.nvim_set_hl(0, combined_name, {
    fg = base_hl.fg,
    bg = selected_bg,
    bold = base_hl.bold,
    italic = base_hl.italic,
    underline = base_hl.underline,
    strikethrough = base_hl.strikethrough,
  })

  return combined_name
end

function M.build_file_display_parts(path, max_width, opts)
  opts = opts or {}
  local full_path = path or ""
  local filename = full_path:match("([^/]+)$") or full_path
  local directory = full_path:sub(1, -(#filename + 1))
  local suffix = opts.suffix or ""

  local filename_len = vim.fn.strdisplaywidth(filename)
  local suffix_len = vim.fn.strdisplaywidth(suffix)
  local available = math.max(max_width - filename_len - suffix_len, 0)

  if #directory == 0 or available <= 0 then
    return {
      filename = filename,
      directory = "",
      suffix = suffix,
    }
  end

  local space_len = 1
  local directory_len = vim.fn.strdisplaywidth(directory)
  if directory_len + space_len <= available then
    return {
      filename = filename,
      directory = directory,
      suffix = suffix,
    }
  end

  local available_for_dir = available - space_len
  if available_for_dir <= 3 then
    return {
      filename = filename,
      directory = "",
      suffix = suffix,
    }
  end

  local ellipsis = "..."
  local chars_to_keep = available_for_dir - vim.fn.strdisplaywidth(ellipsis)
  local byte_pos = 0
  local accumulated_width = 0
  for char in vim.gsplit(directory, "") do
    if char ~= "" then
      local char_width = vim.fn.strdisplaywidth(char)
      if accumulated_width + char_width > chars_to_keep then
        break
      end
      accumulated_width = accumulated_width + char_width
      byte_pos = byte_pos + #char
    end
  end

  return {
    filename = filename,
    directory = byte_pos > 0 and (directory:sub(1, byte_pos) .. ellipsis) or "",
    suffix = suffix,
  }
end

function M.prepare_flat_file_line(file_data, max_width, opts)
  opts = opts or {}
  local line = Line()
  local is_selected = opts.selected == true
  local selection_hl = opts.selection_hl or "CodeDiffExplorerSelected"
  local name_hl = opts.filename_hl or "Normal"
  local path_hl = opts.path_hl or "ExplorerDirectorySmall"
  local normal_hl = opts.normal_hl or "Normal"

  local function get_hl(base_hl)
    if not is_selected then
      return base_hl or normal_hl
    end
    return M.get_selected_highlight(base_hl or normal_hl, selection_hl)
  end

  local icon, icon_color = M.get_file_icon(file_data.path)
  local status_symbol, status_hl = M.get_status_display(file_data.status)

  local icon_part = icon ~= "" and (icon .. " ") or ""
  line:append(" ", get_hl(normal_hl))
  if #icon_part > 0 then
    line:append(icon_part, get_hl(icon_color))
  end

  local suffix = ""
  if file_data.old_path and file_data.old_path ~= file_data.path then
    local current_name = (file_data.path or ""):match("([^/]+)$") or (file_data.path or "")
    local old_name = file_data.old_path:match("([^/]+)$") or file_data.old_path
    local old_dir = file_data.old_path:sub(1, -(#old_name + 1))
    if old_name ~= current_name then
      suffix = " <- " .. old_name
      if #old_dir > 0 then
        suffix = suffix .. " " .. old_dir
      end
    elseif #old_dir > 0 then
      suffix = " <- " .. old_dir
    else
      suffix = " <- " .. file_data.old_path
    end
  end

  local used_width = 1 + vim.fn.strdisplaywidth(icon_part)
  local status_reserve = vim.fn.strdisplaywidth(status_symbol) + 2
  local available_for_content = math.max(max_width - used_width - status_reserve, 0)
  local parts = M.build_file_display_parts(file_data.path, available_for_content, { suffix = suffix })

  line:append(parts.filename, get_hl(name_hl))
  if #parts.directory > 0 then
    line:append(" ", get_hl(normal_hl))
    line:append(parts.directory, get_hl(path_hl))
  end
  if #parts.suffix > 0 then
    line:append(" ", get_hl(normal_hl))
    line:append(parts.suffix, get_hl(path_hl))
  end

  local content_len = vim.fn.strdisplaywidth(parts.filename)
    + (#parts.directory > 0 and (1 + vim.fn.strdisplaywidth(parts.directory)) or 0)
    + (#parts.suffix > 0 and (1 + vim.fn.strdisplaywidth(parts.suffix)) or 0)
  local padding_needed = math.max(available_for_content - content_len + 1, 1)
  line:append(string.rep(" ", padding_needed), get_hl(normal_hl))
  line:append(status_symbol, get_hl(status_hl))

  return line
end

-- Folder icon (configurable via config, with nerd font defaults)
function M.get_folder_icon(is_open)
  local explorer_config = config.options.explorer or {}
  local icons = explorer_config.icons or {}
  local defaults = config.defaults.explorer.icons
  if is_open then
    return icons.folder_open or defaults.folder_open, "Directory"
  else
    return icons.folder_closed or defaults.folder_closed, "Directory"
  end
end

-- Create flat file nodes (list mode)
function M.create_file_nodes(files, git_root, group)
  local nodes = {}
  for _, file in ipairs(files) do
    local icon, icon_color = M.get_file_icon(file.path)
    local status_symbol, status_color = M.get_status_display(file.status)

    nodes[#nodes + 1] = Tree.Node({
      text = file.path,
      data = {
        path = file.path,
        status = file.status,
        old_path = file.old_path, -- For renames: original path before rename
        icon = icon,
        icon_color = icon_color,
        status_symbol = status_symbol,
        status_color = status_color,
        git_root = git_root,
        group = group,
      },
    })
  end
  return nodes
end

-- Create tree nodes with directory hierarchy (tree mode)
function M.create_tree_file_nodes(files, git_root, group)
  -- Build directory structure
  local dir_tree = {}

  for _, file in ipairs(files) do
    local parts = {}
    for part in file.path:gmatch("[^/]+") do
      parts[#parts + 1] = part
    end

    local current = dir_tree
    for i = 1, #parts - 1 do
      local dir_name = parts[i]
      if not current[dir_name] then
        current[dir_name] = { _is_dir = true, _children = {} }
      end
      current = current[dir_name]._children
    end

    -- Add file at leaf
    local filename = parts[#parts]
    current[filename] = {
      _is_dir = false,
      _file = file,
    }
  end

  -- Flatten single-child directory chains (e.g., src/ -> components/ -> ui/ becomes src/components/ui/)
  local function flatten_tree(subtree)
    for key, item in pairs(subtree) do
      if item._is_dir then
        flatten_tree(item._children)
        -- Check if this dir has exactly one child and it's a directory
        local children_keys = {}
        for k in pairs(item._children) do
          children_keys[#children_keys + 1] = k
        end
        if #children_keys == 1 and item._children[children_keys[1]]._is_dir then
          local child_key = children_keys[1]
          local child = item._children[child_key]
          local merged_key = key .. "/" .. child_key
          subtree[merged_key] = child
          subtree[key] = nil
        end
      end
    end
  end

  local explorer_config = config.options.explorer or {}
  if explorer_config.flatten_dirs ~= false then
    flatten_tree(dir_tree)
  end

  -- Convert to Tree.Node recursively
  -- indent_state: array of booleans, true = ancestor at that level is last child
  local function build_nodes(subtree, parent_path, indent_state)
    local nodes = {}
    local sorted_keys = {}

    for key in pairs(subtree) do
      sorted_keys[#sorted_keys + 1] = key
    end
    -- Sort: directories first, then files, alphabetically
    table.sort(sorted_keys, function(a, b)
      local a_is_dir = subtree[a]._is_dir
      local b_is_dir = subtree[b]._is_dir
      if a_is_dir ~= b_is_dir then
        return a_is_dir
      end
      return a < b
    end)

    local total = #sorted_keys
    for idx, key in ipairs(sorted_keys) do
      local item = subtree[key]
      local full_path = parent_path ~= "" and (parent_path .. "/" .. key) or key
      local is_last = (idx == total)

      -- Copy parent indent state and add current level
      local node_indent_state = {}
      for i, v in ipairs(indent_state) do
        node_indent_state[i] = v
      end
      node_indent_state[#node_indent_state + 1] = is_last

      if item._is_dir then
        -- Directory node - children need to know this dir's is_last status
        local children = build_nodes(item._children, full_path, node_indent_state)
        nodes[#nodes + 1] = Tree.Node({
          text = key,
          data = {
            type = "directory",
            name = key,
            dir_path = full_path,
            group = group,
            indent_state = node_indent_state,
          },
        }, children)
      else
        -- File node
        local file = item._file
        local icon, icon_color = M.get_file_icon(file.path)
        local status_symbol, status_color = M.get_status_display(file.status)

        nodes[#nodes + 1] = Tree.Node({
          text = key,
          data = {
            path = file.path,
            status = file.status,
            old_path = file.old_path,
            icon = icon,
            icon_color = icon_color,
            status_symbol = status_symbol,
            status_color = status_color,
            git_root = git_root,
            group = group,
            indent_state = node_indent_state,
          },
        })
      end
    end

    return nodes
  end

  return build_nodes(dir_tree, "", {})
end

-- Prepare node for rendering (format display)
function M.prepare_node(node, max_width, selected_path, selected_group)
  local line = Line()
  local data = node.data or {}
  local explorer_config = config.options.explorer or {}
  local use_indent_markers = explorer_config.indent_markers ~= false -- default true

  -- Helper to build indent string with markers (for tree mode)
  local function build_indent_markers(indent_state)
    if not indent_state or #indent_state == 0 then
      return ""
    end

    if not use_indent_markers then
      -- Plain space indentation
      return string.rep("  ", #indent_state)
    end

    local indent_parts = {}
    -- All levels except the last one: show edge or space
    for i = 1, #indent_state - 1 do
      if indent_state[i] then
        -- Ancestor was last child, show space
        indent_parts[#indent_parts + 1] = INDENT_MARKERS.none .. " "
      else
        -- Ancestor was not last, show edge
        indent_parts[#indent_parts + 1] = INDENT_MARKERS.edge .. " "
      end
    end
    -- Last level: show item or last marker
    if indent_state[#indent_state] then
      indent_parts[#indent_parts + 1] = INDENT_MARKERS.last .. " "
    else
      indent_parts[#indent_parts + 1] = INDENT_MARKERS.item .. " "
    end
    return table.concat(indent_parts)
  end

  if data.type == "group" then
    -- Group header
    line:append(" ", "Directory")
    line:append(node.text, "Directory")
  elseif data.type == "directory" then
    -- Directory node (tree view mode) - with indent markers
    local indent = build_indent_markers(data.indent_state)
    local folder_icon, folder_color = M.get_folder_icon(node:is_expanded())
    if #indent > 0 then
      line:append(indent, use_indent_markers and "NeoTreeIndentMarker" or "Normal")
    end
    line:append(folder_icon .. " ", folder_color or "Directory")
    line:append(data.name, "Directory")
  else
    -- Match both path AND group to handle files in both staged and unstaged
    local is_selected = data.path and data.path == selected_path and data.group == selected_group
    local function get_hl(base_hl)
      if not is_selected then
        return base_hl or "Normal"
      end
      return M.get_selected_highlight(base_hl or "Normal", "CodeDiffExplorerSelected")
    end

    -- Check if we're in tree mode (directory is already shown in hierarchy)
    local view_mode = explorer_config.view_mode or "list"

    -- File entry - VSCode style: filename (bold) + directory (dimmed) + status (right-aligned)
    local indent
    if view_mode == "tree" and data.indent_state then
      indent = build_indent_markers(data.indent_state)
      if #indent > 0 then
        line:append(indent, get_hl(use_indent_markers and "NeoTreeIndentMarker" or "Normal"))
      end
    else
      indent = string.rep("  ", node:get_depth() - 1)
      line:append(indent, get_hl("Normal"))
    end

    local file_line = M.prepare_flat_file_line({
      path = data.path or node.text,
      old_path = data.old_path,
      status = data.status,
    }, max_width - vim.fn.strdisplaywidth(indent), {
      selected = is_selected,
      selection_hl = "CodeDiffExplorerSelected",
      filename_hl = "Normal",
      path_hl = view_mode == "tree" and "Normal" or "ExplorerDirectorySmall",
      normal_hl = "Normal",
    })
    for _, seg in ipairs(file_line._segments) do
      line:append(seg.text, seg.hl)
    end
  end

  return line
end

return M

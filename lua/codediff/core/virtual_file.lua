-- Virtual file scheme for git revisions
-- Inspired by vim-fugitive's fugitive:// URL scheme
-- LSP attachment is prevented via LspAttach guard; semantic tokens
-- are handled separately via semantic_tokens.lua

local M = {}

local api = vim.api
local events = require("codediff.ui.events")
local buffer_highlighting = require("codediff.core.buffer_highlighting")

-- Helper function to load content into a virtual buffer and fire the loaded event
local function load_virtual_buffer_content(buf, git_root, commit, filepath)
  local git = require("codediff.core.git")

  git.get_file_content(commit, git_root, filepath, function(err, lines)
    vim.schedule(function()
      -- Check buffer is still valid (might have been deleted during async fetch)
      if not api.nvim_buf_is_valid(buf) then
        return
      end

      if err then
        -- File doesn't exist in this revision (added/deleted file)
        -- Show empty buffer so diff can highlight the change
        vim.bo[buf].modifiable = true
        vim.bo[buf].readonly = false
        api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
        vim.bo[buf].modifiable = false
        vim.bo[buf].readonly = true
        vim.bo[buf].filetype = ""
        vim.diagnostic.enable(false, { bufnr = buf })

        -- Fire loaded event so diff rendering proceeds
        events.emit("CodeDiffVirtualFileLoaded", { buf = buf })
        return
      end

      -- Set the content
      if not api.nvim_buf_is_valid(buf) then
        -- Buffer was deleted while we were fetching, skip
        return
      end
      vim.bo[buf].modifiable = true
      vim.bo[buf].readonly = false
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      -- Make it read-only
      vim.bo[buf].modifiable = false
      vim.bo[buf].readonly = true

      -- Start TreeSitter highlighting directly without setting filetype.
      -- Setting filetype fires FileType autocmd, which triggers LSP plugins
      -- to attach and send textDocument/didOpen with codediff:// URI,
      -- crashing language servers that can't handle custom URI schemes.
      local ft = vim.filetype.match({ filename = filepath, buf = buf })
      buffer_highlighting.apply_scratch_highlighting(buf, ft)

      events.emit("CodeDiffVirtualFileLoaded", { buf = buf })
    end)
  end)
end

-- Refresh a virtual buffer's content (for mutable revisions like :0)
function M.refresh_buffer(buf)
  local bufname = api.nvim_buf_get_name(buf)
  local git_root, commit, filepath = M.parse_url(bufname)

  if not git_root or not commit or not filepath then
    return false
  end

  load_virtual_buffer_content(buf, git_root, commit, filepath)
  return true
end

-- Create a fugitive-style URL for a git revision
-- Format: corkdiff:///<git-root>///<commit>/<filepath>
-- Supports commit hash or :0 (staged index)
function M.create_url(git_root, commit, filepath)
  -- Normalize and encode components
  local encoded_root = vim.fn.fnamemodify(git_root, ":p")
  -- Remove trailing slashes (both / and \)
  encoded_root = encoded_root:gsub("[/\\]$", "")
  -- Normalize to forward slashes
  encoded_root = encoded_root:gsub("\\", "/")

  local encoded_commit = commit or "HEAD"
  local encoded_path = filepath:gsub("^/", "")

  return string.format("corkdiff:///%s///%s/%s", encoded_root, encoded_commit, encoded_path)
end

-- Parse a corkdiff:// or codediff:// URL
-- Returns: git_root, commit, filepath
function M.parse_url(url)
  local scheme = url:match("^([a-z%-]+):///")
  if scheme ~= "corkdiff" and scheme ~= "codediff" then
    return nil, nil, nil
  end

  -- Pattern accepts SHA hash (hex chars)
  local pattern = "^[a-z%-]+:///(.-)///([a-fA-F0-9]+)/(.+)$"
  local git_root, commit, filepath = url:match(pattern)
  if git_root and commit and filepath then
    return git_root, commit, filepath
  end

  -- Try SHA with ^ suffix (parent commit reference)
  local pattern_parent = "^[a-z%-]+:///(.-)///([a-fA-F0-9]+%^)/(.+)$"
  git_root, commit, filepath = url:match(pattern_parent)
  if git_root and commit and filepath then
    return git_root, commit, filepath
  end

  -- Try symbolic ref pattern (HEAD, branch names, etc.)
  local pattern_symbolic = "^[a-z%-]+:///(.-)///([A-Za-z][A-Za-z0-9_~^%-]*)/(.+)$"
  git_root, commit, filepath = url:match(pattern_symbolic)
  if git_root and commit and filepath then
    return git_root, commit, filepath
  end

  -- Try :N or :N: pattern for staged index (supports :0, :1:, :2:, :3:)
  local pattern_staged = "^[a-z%-]+:///(.-)///(:[0-9]:?)/(.+)$"
  git_root, commit, filepath = url:match(pattern_staged)
  return git_root, commit, filepath
end

local function register_scheme_autocmds(group, scheme)
  api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = scheme .. ":///*",
    callback = function(args)
      local url = args.match
      local buf = args.buf

      local git_root, commit, filepath = M.parse_url(url)

      if not git_root or not commit or not filepath then
        vim.notify("Invalid corkdiff URL: " .. url, vim.log.levels.ERROR)
        return
      end

      -- Set buffer options FIRST to prevent LSP attachment
      vim.bo[buf].buftype = "nowrite"
      vim.bo[buf].bufhidden = "wipe"

      -- Clear any auto-detected filetype without firing FileType autocmd.
      -- Neovim's built-in filetype detection matches the .js/.ts/.tf extension
      -- in corkdiff:// URLs and sets filetype, which triggers LSP plugins to
      -- attach and crash on the custom URI scheme.
      vim.cmd("noautocmd setlocal filetype=")

      -- Load content using the shared helper
      load_virtual_buffer_content(buf, git_root, commit, filepath)
    end,
  })

  api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = scheme .. ":///*",
    callback = function()
      vim.notify("Cannot write to git revision buffer", vim.log.levels.WARN)
    end,
  })
end

function M.setup()
  -- Create autocmd group
  local group = api.nvim_create_augroup("CorkDiffVirtualFile", { clear = true })

  register_scheme_autocmds(group, "corkdiff")
  register_scheme_autocmds(group, "codediff")
end

return M

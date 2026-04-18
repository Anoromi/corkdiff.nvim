local M = {}

local function install_alias_searcher()
  if vim.g.corkdiff_alias_searcher_installed == 1 then
    return
  end

  local searchers = package.searchers or package.loaders
  if not searchers then
    return
  end

  local function corkdiff_alias_searcher(module_name)
    if not module_name:match("^corkdiff%.") then
      return nil
    end

    local mapped_module = module_name:gsub("^corkdiff", "codediff", 1)
    return function()
      return require(mapped_module)
    end
  end

  table.insert(searchers, 1, corkdiff_alias_searcher)
  vim.g.corkdiff_alias_searcher_installed = 1
end

local function complete_flags(candidates, arg_lead)
  local filtered = {}
  for _, flag in ipairs(candidates) do
    if flag:find(arg_lead, 1, true) == 1 then
      table.insert(filtered, flag)
    end
  end

  if #filtered > 0 then
    return filtered
  end

  return nil
end

local rev_cache = {
  candidates = nil,
  git_root = nil,
  timestamp = 0,
  ttl = 5,
}

local function get_cached_rev_candidates(git_root)
  local git = require("codediff.core.git")
  local now = vim.loop.now() / 1000

  if rev_cache.candidates
      and rev_cache.git_root == git_root
      and (now - rev_cache.timestamp) < rev_cache.ttl then
    return rev_cache.candidates
  end

  local candidates = git.get_rev_candidates(git_root)
  rev_cache.candidates = candidates
  rev_cache.git_root = git_root
  rev_cache.timestamp = now
  return candidates
end

local function complete_diff(arg_lead, cmd_line, _)
  local git = require("codediff.core.git")
  local commands = require("codediff.commands")
  local args = vim.split(cmd_line, "%s+", { trimempty = true })

  if #args <= 1 then
    local candidates = vim.list_extend({}, commands.SUBCOMMANDS)
    local cwd = vim.fn.getcwd()
    local git_root = git.get_git_root_sync(cwd)
    local rev_candidates = get_cached_rev_candidates(git_root)
    if rev_candidates then
      vim.list_extend(candidates, rev_candidates)
    end
    return candidates
  end

  local first_arg = args[2]
  if first_arg == "merge" or first_arg == "file" then
    return vim.fn.getcompletion(arg_lead, "file")
  end

  if arg_lead:match("^%-") then
    if first_arg == "history" then
      local result = complete_flags({ "--reverse", "-r", "--base", "-b", "--inline", "--side-by-side", "--combined" }, arg_lead)
      if result then
        return result
      end
    end

    local result = complete_flags({ "--inline", "--side-by-side", "--combined" }, arg_lead)
    if result then
      return result
    end
  end

  if #args == 2 and arg_lead ~= "" then
    local cwd = vim.fn.getcwd()
    local git_root = git.get_git_root_sync(cwd)
    local rev_candidates = get_cached_rev_candidates(git_root)
    local filtered = {}

    local base_rev = arg_lead:match("^(.+)%.%.%.$")
    if base_rev then
      if rev_candidates then
        for _, candidate in ipairs(rev_candidates) do
          table.insert(filtered, base_rev .. "..." .. candidate)
        end
      end

      table.insert(filtered, 1, arg_lead)
      return filtered
    end

    if rev_candidates then
      for _, candidate in ipairs(rev_candidates) do
        if candidate:find(arg_lead, 1, true) == 1 then
          table.insert(filtered, candidate)
          table.insert(filtered, candidate .. "...")
        end
      end
    end

    if #filtered > 0 then
      return filtered
    end
  end

  return vim.fn.getcompletion(arg_lead, "file")
end

local function create_command(name, desc)
  if vim.fn.exists(":" .. name) == 2 then
    return
  end

  vim.api.nvim_create_user_command(name, function(opts)
    require("codediff.commands").vscode_diff(opts)
  end, {
    nargs = "*",
    bang = true,
    range = true,
    complete = complete_diff,
    desc = desc,
  })
end

function M.setup()
  install_alias_searcher()

  if vim.g.loaded_corkdiff_core ~= 1 then
    vim.g.loaded_corkdiff_core = 1
    vim.g.loaded_corkdiff = 1
    vim.g.loaded_codediff = 1

    local highlights = require("codediff.ui.highlights")
    local virtual_file = require("codediff.core.virtual_file")

    virtual_file.setup()
    highlights.setup()

    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("CorkDiffHighlights", { clear = true }),
      callback = function()
        highlights.setup()
      end,
    })
  else
    vim.g.loaded_corkdiff = 1
    vim.g.loaded_codediff = 1
  end

  create_command("CorkDiff", "VSCode-style diff view: :CorkDiff [<revision>] | merge <file> | file <revision> | install")
  create_command("CodeDiff", "VSCode-style diff view (legacy alias for :CorkDiff)")
end

return M

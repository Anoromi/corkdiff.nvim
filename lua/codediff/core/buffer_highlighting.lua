local M = {}

function M.apply_scratch_highlighting(bufnr, filetype)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if not filetype or filetype == "" then
    vim.diagnostic.enable(false, { bufnr = bufnr })
    return
  end

  local lang = vim.treesitter.language.get_lang(filetype) or filetype
  if pcall(vim.treesitter.start, bufnr, lang) then
    vim.bo[bufnr].syntax = ""
  else
    vim.bo[bufnr].syntax = filetype
  end

  vim.diagnostic.enable(false, { bufnr = bufnr })
end

return M

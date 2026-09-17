if vim.g.loaded_md_table_wrap then
  return
end
vim.g.loaded_md_table_wrap = 1

-- conceal_lines, which hides the source lines of a table, arrived in 0.11.
if vim.fn.has("nvim-0.11.0") == 0 then
  vim.notify("md-table-wrap.nvim requires at least nvim-0.11.0", vim.log.levels.ERROR)
  return
end

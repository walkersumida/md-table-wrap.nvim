local M = {}

M.defaults = {
  enabled = true,

  -- Filetypes the tables are rendered in.
  filetypes = { "markdown" },

  -- The source of a table is hidden with conceal, so a window showing one of the
  -- filetypes with 'conceallevel' at 0 gets this level instead. The level applies to
  -- every conceal in the window, such as the markers and link destinations Neovim
  -- hides in markdown. Set to false to leave the option alone.
  conceallevel = 2,

  -- A column is never squeezed below this width while the table is being fitted to
  -- the window.
  min_col_width = 8,

  -- Milliseconds to wait after an event before redrawing.
  debounce = 50,

  -- Milliseconds to keep re-measuring the window after a buffer opens. Other plugins
  -- place their signs after the first draw, which changes the width left for the
  -- table.
  settle_time = 1000,

  -- Number of parsed cells kept in memory.
  cache_size = 2000,

  -- Highlight groups applied to the drawn table. The inline keys are the treesitter
  -- node names of the markdown_inline parser.
  highlights = {
    header = { "Title" },
    code_span = { "@markup.raw.markdown_inline", "RenderMarkdownCodeInline" },
    strong_emphasis = { "@markup.strong" },
    emphasis = { "@markup.italic" },
    strikethrough = { "@markup.strikethrough" },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
  return M.options
end

function M.get()
  return M.options
end

return M

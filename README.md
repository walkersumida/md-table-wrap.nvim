# md-table-wrap.nvim

Markdown tables in Neovim break as soon as they are wider than the window: with `wrap`
on, a row folds at column zero and the columns stop lining up; with `wrap` off, the
right-hand columns are simply off screen.

This plugin draws the table in place instead. The source lines are hidden and replaced
by a table that fits the window, with cell contents wrapped and the columns still
aligned. The buffer text is never modified.

![Neovim](https://img.shields.io/badge/Neovim-0.11+-green.svg)
![Lua](https://img.shields.io/badge/Lua-blue.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

```
┌───────────────┬──────────────────────────┐
│ Option        │ Description              │
├───────────────┼──────────────────────────┤
│ min_col_width │ Lower bound while        │
│               │ columns are squeezed     │
├───────────────┼──────────────────────────┤
│ debounce      │ Milliseconds to wait     │
│               │ before redrawing         │
├───────────────┼──────────────────────────┤
│ filetypes     │ Filetypes the tables are │
│               │ rendered in              │
└───────────────┴──────────────────────────┘
```

## Features

- Cells wrap and the columns stay aligned, at any window width
- Widths are measured in display cells, so CJK text and emoji keep the columns
  aligned, and a line is never broken in the middle of an emoji
- Inline code, bold, italic and strikethrough keep their highlighting; the markers
  themselves are hidden
- The table stays drawn while the cursor moves over it, with only the row under the cursor
  shown as markdown source in place; insert mode brings back the source for editing
- Columns are squeezed from the widest one until the table fits the window, and every
  window showing the buffer is laid out for its own width
- `:MdTableWrapFloat` opens the table under the cursor in a floating window as plain
  text, laid out for the width of the whole editor, where the cursor moves over the
  characters as drawn

## Requirements

- Neovim >= 0.11 (the `conceal_lines` extmark option)
- The bundled `markdown_inline` treesitter parser, for inline highlighting. Without it
  the tables still render, with the markers left in the text.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "walkersumida/md-table-wrap.nvim",
  ft = "markdown",
  opts = {},
}
```

If you use [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim),
turn its own table rendering off so the two do not draw over each other. Add the visual
modes to its `render_modes` as well: outside those modes it sets `'conceallevel'` back
to your default, and the tables fall back to source while you select.

```lua
{
  "MeanderingProgrammer/render-markdown.nvim",
  opts = {
    pipe_table = { enabled = false },
    -- render-markdown.nvim turns conceal off outside these modes, which would show
    -- the tables as source while selecting
    render_modes = { "n", "c", "t", "v", "V", "\22" },
  },
}
```

## Configuration

`setup()` takes the options below. The defaults are shown.

```lua
require("md-table-wrap").setup({
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
})
```

## Commands and API

| Command | Description |
|---|---|
| `:MdTableWrap` | Toggle the rendering for the current buffer |
| `:MdTableWrapFloat` | Open the table under the cursor in a floating window; `q` or `<Esc>` closes it |

```lua
require("md-table-wrap").toggle()  -- current buffer
require("md-table-wrap").enable()  -- every attached buffer
require("md-table-wrap").disable()
require("md-table-wrap").open_float()  -- table under the cursor
```

No key is mapped by default. To open the float with a key:

```lua
vim.keymap.set("n", "<leader>tf", function()
  require("md-table-wrap").open_float()
end, { desc = "Open the markdown table in a float" })
```

## How it works

- The source lines of a table are hidden with conceal and a table that fits the
  window is drawn in their place as virtual lines. The buffer text is never changed.
- Conceal needs `'conceallevel'` above 0, so a window showing markdown with the level
  at 0 is given the `conceallevel` option (`:setlocal`) when the buffer is shown. If
  another plugin lowers it afterwards, the tables are left as source until it is
  raised again.

## Limitations

- A table that starts on line one and runs to the end of the buffer has no neighbouring
  line to attach the drawn table to, and is left as source
- Scoping a namespace to a window is experimental (`nvim__ns_set`). Where it is missing,
  only one window of a buffer is rendered at a time
- Variation selectors are dropped from the drawn text: terminals and Neovim disagree
  about the width of an emoji presentation, and one cell of disagreement breaks every
  column to its right
- Links keep their markup
- A visual selection is highlighted on source lines only. The drawn rows are virtual
  text and stay unhighlighted, while yanking or deleting still acts on the source
  lines of the table

## Development

```sh
make test              # run the suite
make test-file FILE=tests/text_spec.lua
```

`tests/screen_spec.lua` runs a second Neovim in a pty and reads its screen over RPC, which
is the only way to check what a drawn table, and the source line under the cursor, really
look like.

## License

MIT

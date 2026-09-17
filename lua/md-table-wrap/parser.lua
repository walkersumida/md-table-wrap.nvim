local config = require("md-table-wrap.config")

local M = {}

local INLINE_DELIMITER = {
  code_span_delimiter = true,
  emphasis_delimiter = true,
}

-- Parsing a cell costs more than laying it out, and every cell of a table is parsed
-- again whenever the buffer changes or a window is resized. Cells leaving the buffer
-- cannot be told apart from cells still in it, so the whole cache goes once it holds
-- more entries than configured.
local cache = {}
local cache_size = 0

function M.clear_cache()
  cache = {}
  cache_size = 0
end

local function remember(cell, text, styles, chars)
  if cache_size >= config.get().cache_size then
    M.clear_cache()
  end
  cache[cell] = { text, styles, chars }
  cache_size = cache_size + 1
  return text, styles, chars
end

-- Only unescaped pipes separate cells.
---@return string[]
function M.split_cells(line)
  local body = line:gsub("^%s*|", ""):gsub("|%s*$", "")
  local cells = {}
  local current = {}
  local i = 1
  while i <= #body do
    local c = body:sub(i, i)
    if c == "\\" and body:sub(i + 1, i + 1) == "|" then
      table.insert(current, "|")
      i = i + 2
    elseif c == "|" then
      table.insert(cells, table.concat(current))
      current = {}
      i = i + 1
    else
      table.insert(current, c)
      i = i + 1
    end
  end
  table.insert(cells, table.concat(current))

  for idx, cell in ipairs(cells) do
    cells[idx] = vim.trim(cell)
  end
  return cells
end

function M.is_delimiter_row(cells)
  for _, cell in ipairs(cells) do
    if not cell:match("^:?%-+:?$") then
      return false
    end
  end
  return #cells > 0
end

-- A <br> is a line break within the cell, which the drawn cell keeps as a newline.
-- Variation selectors request an emoji presentation whose width terminals and Neovim
-- disagree about, and a disagreement of one cell breaks every column to its right.
function M.clean_cell(cell)
  local text = cell:gsub("<br%s*/?>", "\n")
  text = text:gsub("\239\184\142", ""):gsub("\239\184\143", "")
  return vim.trim(text)
end

-- Splits a cell into the text to draw and the highlight groups of each character.
-- Markers are dropped along with the node that owns them, so `a**b**c` inside a code
-- span keeps its asterisks while a real emphasis loses them.
---@return string text, string[][]|nil styles, string[]|nil chars
function M.parse_inline(text)
  local cached = cache[text]
  if cached then
    return cached[1], cached[2], cached[3]
  end

  local ok, root = pcall(function()
    return vim.treesitter.get_string_parser(text, "markdown_inline"):parse()[1]:root()
  end)
  if not ok then
    return text, nil, nil
  end

  local highlights = config.get().highlights
  local cuts, spans = {}, {}
  local function collect(node)
    local kind = node:type()
    if INLINE_DELIMITER[kind] or highlights[kind] then
      local _, _, from = node:start()
      local _, _, to = node:end_()
      table.insert(INLINE_DELIMITER[kind] and cuts or spans, { from = from, to = to, hl = highlights[kind] })
    end
    for child in node:iter_children() do
      collect(child)
    end
  end
  collect(root)

  -- A cell of plain text is the common one, and parsing it costs as much as parsing one
  -- that is marked up, so it is kept like any other.
  if #cuts == 0 and #spans == 0 then
    return remember(text, text, nil, nil)
  end

  local starts = vim.str_utf_pos(text)
  local chars, styles = {}, {}
  for idx = 1, #starts do
    local from = starts[idx] - 1
    local to = (starts[idx + 1] or #text + 1) - 1
    local dropped = false
    for _, cut in ipairs(cuts) do
      if from >= cut.from and to <= cut.to then
        dropped = true
        break
      end
    end
    if not dropped then
      table.insert(chars, text:sub(from + 1, to))
      local hl = nil
      for _, span in ipairs(spans) do
        if from >= span.from and to <= span.to then
          hl = hl or {}
          vim.list_extend(hl, span.hl)
        end
      end
      styles[#chars] = hl
    end
  end

  return remember(text, table.concat(chars), styles, chars)
end

-- The virtual lines shrink the viewport, so a search limited to the visible range
-- would drop the table it just drew and redraw it on the next event. Fenced code
-- blocks are skipped because a line inside one can start with a pipe.
---@return { first: integer, last: integer }[]
function M.find_tables(lines)
  local tables = {}
  local in_fence = false
  local n = 1
  while n <= #lines do
    if lines[n]:match("^%s*```") or lines[n]:match("^%s*~~~") then
      in_fence = not in_fence
      n = n + 1
    elseif in_fence or not lines[n]:match("^%s*|") then
      n = n + 1
    else
      local first = n
      while n <= #lines and lines[n]:match("^%s*|") do
        n = n + 1
      end
      table.insert(tables, { first = first, last = n - 1 })
    end
  end
  return tables
end

-- The delimiter row is not a row to draw, only the marker of where the header ends.
-- Every cell carries the text to draw plus the highlights of its characters, and the
-- line numbers say where each row sits in the buffer.
---@return table[]|nil header, table[][] rows, { header: integer?, delimiter: integer?, rows: integer[] } lnums
function M.rows(lines, first, last)
  local header, rows, lnums = nil, {}, { rows = {} }
  for n = first, last do
    local cells = M.split_cells(lines[n])
    if M.is_delimiter_row(cells) then
      lnums.delimiter = lnums.delimiter or n
    else
      local parsed = {}
      for idx, cell in ipairs(cells) do
        local text, styles, chars = M.parse_inline(M.clean_cell(cell))
        parsed[idx] = { text = text, styles = styles, chars = chars }
      end
      if not header then
        header = parsed
        lnums.header = n
      else
        table.insert(rows, parsed)
        table.insert(lnums.rows, n)
      end
    end
  end
  return header, rows, lnums
end

return M

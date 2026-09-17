local config = require("md-table-wrap.config")
local text = require("md-table-wrap.text")

local M = {}

-- Columns taken up by the borders and by one space of padding on either side of every
-- cell.
local function frame_width(columns)
  return 3 * columns + 1
end

local function natural_widths(rows, columns)
  local widths = {}
  for col = 1, columns do
    local width = 0
    for _, row in ipairs(rows) do
      local cell = row[col]
      for _, segment in ipairs(vim.split(cell and cell.text or "", "\n", { plain = true })) do
        width = math.max(width, text.width(segment))
      end
    end
    widths[col] = math.max(width, 1)
  end
  return widths
end

-- Take a column from the widest one at a time until the table fits. A table that still
-- does not fit once every column is at the minimum overflows to the right.
local function shrink_to_fit(widths, budget)
  local minimum = config.get().min_col_width
  local total = frame_width(#widths)
  for _, w in ipairs(widths) do
    total = total + w
  end
  while total > budget do
    local target, widest = nil, minimum
    for col, w in ipairs(widths) do
      if w > widest then
        target, widest = col, w
      end
    end
    if not target then
      break
    end
    widths[target] = widths[target] - 1
    total = total - 1
  end
end

local function border_line(widths, left, middle, right)
  local parts = {}
  for _, w in ipairs(widths) do
    table.insert(parts, string.rep("─", w + 2))
  end
  return left .. table.concat(parts, middle) .. right
end

-- Groups the characters of one wrapped line into as few [text, highlight] chunks as
-- the virtual line needs.
local function line_chunks(cell, line, base_hl)
  if not cell.styles then
    return { { line.text, base_hl } }
  end

  local chunks, buffer = {}, {}
  local chunk_style, hl = nil, nil
  local function flush()
    if #buffer > 0 then
      table.insert(chunks, { table.concat(buffer), hl })
      buffer = {}
    end
  end

  for idx = line.from, line.to do
    local style = cell.styles[idx]
    local style_key = style and table.concat(style, ",") or ""
    if style_key ~= chunk_style then
      flush()
      chunk_style = style_key
      if not style then
        hl = base_hl
      elseif not base_hl then
        hl = style
      else
        hl = vim.list_extend(vim.list_extend({}, base_hl), style)
      end
    end
    table.insert(buffer, cell.chars[idx])
  end
  flush()
  return chunks
end

---@return table[][] one list of chunks per physical line
local function render_row(cells, widths, base_hl)
  local wrapped, height = {}, 1
  for col, w in ipairs(widths) do
    local cell = cells[col] or { text = "" }
    local lines = text.wrap(cell.text, w)
    if #lines == 0 then
      lines = { { text = "", from = 1, to = 0 } }
    end
    wrapped[col] = { cell = cell, lines = lines }
    height = math.max(height, #lines)
  end

  local out = {}
  for row = 1, height do
    local chunks = { { "│ " } }
    for col, w in ipairs(widths) do
      if col > 1 then
        table.insert(chunks, { " │ " })
      end
      local line = wrapped[col].lines[row]
      if line then
        vim.list_extend(chunks, line_chunks(wrapped[col].cell, line, base_hl))
      end
      local pad = w - text.width(line and line.text or "")
      if pad > 0 then
        table.insert(chunks, { string.rep(" ", pad) })
      end
    end
    table.insert(chunks, { " │" })
    table.insert(out, chunks)
  end
  return out
end

-- Lays the table out within budget columns. The ranges give the drawn lines that stand
-- for the header, the delimiter row and each data row.
---@return table[][] lines, { header: integer[], delimiter: integer[], rows: integer[][] } ranges
function M.build(header, rows, budget)
  local all = { header }
  vim.list_extend(all, rows)

  local widths = natural_widths(all, #header)
  shrink_to_fit(widths, budget)

  local lines = {}
  local function border(left, middle, right)
    table.insert(lines, { { border_line(widths, left, middle, right) } })
  end
  local function add(row_lines)
    local from = #lines + 1
    for _, chunks in ipairs(row_lines) do
      table.insert(lines, chunks)
    end
    return { from, #lines }
  end

  border("┌", "┬", "┐")
  local ranges = { header = add(render_row(header, widths, config.get().highlights.header)), rows = {} }
  border("├", "┼", "┤")
  ranges.delimiter = { #lines, #lines }

  -- Once cells wrap over several lines, rows run together without a rule between them.
  local rendered = {}
  local multiline = false
  for idx, row in ipairs(rows) do
    rendered[idx] = render_row(row, widths)
    multiline = multiline or #rendered[idx] > 1
  end

  for idx, row_lines in ipairs(rendered) do
    if multiline and idx > 1 then
      border("├", "┼", "┤")
    end
    ranges.rows[idx] = add(row_lines)
  end
  border("└", "┴", "┘")

  return lines, ranges
end

return M

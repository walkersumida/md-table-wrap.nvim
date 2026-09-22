-- Shows the table under the cursor in a floating window as plain buffer text. The cursor
-- moves over real characters there, so a wide table can be read, searched and yanked
-- from at the width of the whole editor.

local parser = require("md-table-wrap.parser")
local render = require("md-table-wrap.render")

local M = {}

local ns = vim.api.nvim_create_namespace("md_table_wrap_float")

-- Cells left free around the float, across and down, so that it does not look like a split.
local MARGIN = 4

---@return table[]|nil header, table[][] rows, table lnums
local function table_at(lines, lnum)
  for _, found in ipairs(parser.find_tables(lines)) do
    if lnum >= found.first and lnum <= found.last then
      local header, rows, lnums = parser.rows(lines, found.first, found.last)
      if header and #rows > 0 then
        return header, rows, lnums
      end
      return nil
    end
  end
  return nil
end

-- The first drawn line of the source line lnum. The delimiter row and any line the
-- layout does not use land on the rule after the header.
local function drawn_line(lnum, lnums, ranges)
  if lnum == lnums.header then
    return ranges.header[1]
  end
  for idx, row in ipairs(lnums.rows) do
    if lnum == row then
      return ranges.rows[idx][1]
    end
  end
  return ranges.delimiter[1]
end

-- Writes the chunks of the drawn table as buffer lines, with every styled chunk as a
-- highlighted range.
local function fill(bufnr, virt)
  local lines = {}
  for idx, chunks in ipairs(virt) do
    local parts = {}
    for _, chunk in ipairs(chunks) do
      parts[#parts + 1] = chunk[1]
    end
    lines[idx] = table.concat(parts)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  for idx, chunks in ipairs(virt) do
    local col = 0
    for _, chunk in ipairs(chunks) do
      local finish = col + #chunk[1]
      if chunk[2] then
        vim.api.nvim_buf_set_extmark(bufnr, ns, idx - 1, col, { end_col = finish, hl_group = chunk[2] })
      end
      col = finish
    end
  end
  vim.bo[bufnr].modifiable = false
  return lines
end

--- Opens the table under the cursor in a floating window.
function M.open()
  local source = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local header, rows, lnums = table_at(vim.api.nvim_buf_get_lines(source, 0, -1, false), lnum)
  if not header then
    vim.notify("md-table-wrap: no table under the cursor", vim.log.levels.WARN)
    return
  end

  local virt, ranges = render.build(header, rows, vim.o.columns - MARGIN)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  local lines = fill(bufnr, virt)

  local width = math.min(vim.fn.strdisplaywidth(lines[1]), vim.o.columns - MARGIN)
  local height = math.min(#lines, math.max(1, vim.o.lines - vim.o.cmdheight - MARGIN))
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - vim.o.cmdheight - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "none",
  })
  -- A table still wider than the editor at the minimum column width scrolls sideways.
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_cursor(win, { drawn_line(lnum, lnums, ranges), 0 })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, close, { buffer = bufnr, nowait = true, desc = "Close the table" })
  end
  -- The window layout cannot change while a window is being left.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = bufnr,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
  return win
end

return M

-- Renders markdown pipe tables in place with wrapped cells: the source lines are hidden
-- with a conceal_lines extmark and a virt_lines extmark draws a table that fits the
-- window. Every window gets its own namespace, so a table follows the cursor of the
-- window it is drawn in without changing what the other windows show.

local config = require("md-table-wrap.config")
local float = require("md-table-wrap.float")
local parser = require("md-table-wrap.parser")
local render = require("md-table-wrap.render")

local M = {}

local GROUP = vim.api.nvim_create_augroup("MdTableWrap", { clear = true })
-- Scoping a namespace to a window is experimental. Without it the marks of one window
-- would be drawn in all of them, so only one window is rendered.
local scoped = vim.api.nvim__ns_set ~= nil

local timers = {}
local attached = {}
local layouts = {}
local windows = {}
local namespaces = {}
local toplines = {}
local views = {}

local function ns_for(win)
  local ns = namespaces[win]
  if not ns then
    ns = vim.api.nvim_create_namespace("md_table_wrap:" .. win)
    if scoped then
      pcall(vim.api.nvim__ns_set, ns, { wins = { win } })
    end
    namespaces[win] = ns
  end
  return ns
end

local function buffer_windows(bufnr)
  local found = vim.fn.win_findbuf(bufnr)
  if scoped or #found < 2 then
    return found
  end
  local current = vim.api.nvim_get_current_win()
  return vim.tbl_contains(found, current) and { current } or { found[1] }
end

local function text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
end

-- Virtual lines attached to a concealed line are not drawn, so they hang off a
-- neighbouring line: above the line after the table, so that a window can show part of
-- the table while starting on a line that is not concealed, or below the line before a
-- table that ends the buffer.
---@return integer|nil row, boolean above
local function anchor_for(lines, first, last)
  if last < #lines then
    return last, true
  end
  if first > 1 then
    return first - 2, false
  end
  return nil
end

-- The drawn table for every table in the buffer, at one width.
local function build_tables(bufnr, budget)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tables = {}
  for _, found in ipairs(parser.find_tables(lines)) do
    local header, rows, lnums = parser.rows(lines, found.first, found.last)
    local anchor, above = anchor_for(lines, found.first, found.last)
    if header and #rows > 0 and anchor then
      local virt, ranges = render.build(header, rows, budget)
      local spans = { [lnums.header] = ranges.header }
      if lnums.delimiter then
        spans[lnums.delimiter] = ranges.delimiter
      end
      for idx, lnum in ipairs(lnums.rows) do
        spans[lnum] = ranges.rows[idx]
      end
      table.insert(tables, {
        first = found.first,
        last = found.last,
        end_col = #lines[found.last],
        anchor = anchor,
        above = above,
        virt = virt,
        spans = spans,
      })
    end
  end
  return tables
end

local function layout_for(bufnr, budget)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = layouts[bufnr]
  if not cached or cached.tick ~= tick then
    cached = { tick = tick, widths = {} }
    layouts[bufnr] = cached
  end
  if not cached.widths[budget] then
    cached.widths[budget] = { tables = build_tables(bufnr, budget) }
  end
  return cached.widths[budget]
end

-- The drawn lines that stand for a source line. A line the table layout does not use,
-- such as a second delimiter row, takes up no drawn lines just before the next row.
local function span_of(entry, lnum)
  for n = lnum, entry.last do
    local span = entry.spans[n]
    if span then
      if n == lnum then
        return span[1], span[2]
      end
      return span[1], span[1] - 1
    end
  end
  return #entry.virt + 1, #entry.virt
end

local function place(bufnr, ns, id, row, lines, above)
  local opts = { id = id }
  if #lines > 0 then
    opts.virt_lines = lines
    opts.virt_lines_above = above
  end
  return vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, opts)
end

-- Adding or removing conceal_lines changes how many screen lines the buffer occupies.
-- Outside of a redraw cycle that leaves the previous frame on screen, so the change has
-- to be announced.
local function invalidate(bufnr)
  pcall(vim.api.nvim__redraw, { buf = bufnr, valid = false })
end

local function clear_window(win)
  local state = windows[win]
  if not state then
    return
  end
  if vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_clear_namespace(state.bufnr, ns_for(win), 0, -1)
    invalidate(state.bufnr)
  end
  windows[win] = nil
end

local function clear_buffer(bufnr)
  for win, state in pairs(windows) do
    if state.bufnr == bufnr then
      clear_window(win)
    end
  end
  layouts[bufnr] = nil
end

-- Insert mode shows the source so the table can be edited. Anywhere else the deciding
-- factor is conceallevel: a renderer that drops it to 0 brings the hidden source lines
-- back next to the virtual ones, and the table would appear twice.
local EDITING_MODE = {
  i = true,
  R = true,
  s = true,
  S = true,
}

local function renderable(win)
  local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
  if EDITING_MODE[mode] then
    return false
  end
  return vim.api.nvim_win_is_valid(win) and vim.wo[win].conceallevel > 0
end

-- Conceal does nothing at conceallevel 0, so a window gets the configured level when a
-- buffer is shown in it. The level is raised only then: a renderer that lowers it
-- afterwards, as render-markdown.nvim does outside its render modes, does so to show
-- the source, and raising it again would take that view away.
local function enable_conceal(bufnr, wins)
  local level = config.get().conceallevel
  if not level or not config.get().enabled or vim.b[bufnr].md_table_wrap_disabled then
    return
  end
  for _, win in ipairs(wins or vim.fn.win_findbuf(bufnr)) do
    if vim.wo[win].conceallevel == 0 then
      vim.api.nvim_set_option_value("conceallevel", level, { scope = "local", win = win })
    end
  end
end

-- Neovim draws the line under the cursor even inside a concealed range, together with
-- the virtual lines attached to it. Splitting the table there shows the source of the
-- cursor line in place of its drawn rows, with the rest of the table around it.
local function split_at(bufnr, ns, entry, marks, lnum)
  local from, to = span_of(entry, lnum)
  local before = vim.list_slice(entry.virt, 1, from - 1)
  local after = vim.list_slice(entry.virt, to + 1)
  local on_anchor, on_cursor = before, after
  if entry.above then
    on_anchor, on_cursor = after, before
  end
  place(bufnr, ns, marks.anchor_id, entry.anchor, on_anchor, entry.above)
  marks.cursor_id = place(bufnr, ns, marks.cursor_id, lnum - 1, on_cursor, entry.above)
end

local function join(bufnr, ns, entry, marks)
  place(bufnr, ns, marks.anchor_id, entry.anchor, entry.virt, entry.above)
  if marks.cursor_id then
    vim.api.nvim_buf_del_extmark(bufnr, ns, marks.cursor_id)
    marks.cursor_id = nil
  end
end

local function draw_window(win, bufnr, layout)
  local ns = ns_for(win)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local marks = {}
  for _, entry in ipairs(layout.tables) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, entry.first - 1, 0, {
      end_row = entry.last - 1,
      end_col = entry.end_col,
      conceal_lines = "",
    })
    marks[entry.first] = {
      entry = entry,
      anchor_id = vim.api.nvim_buf_set_extmark(bufnr, ns, entry.anchor, 0, {
        virt_lines = entry.virt,
        virt_lines_above = entry.above,
      }),
    }
  end
  windows[win] = { bufnr = bufnr, layout = layout, marks = marks }
end

-- What the top of a window shows, in terms that survive splitting and joining a table:
-- either a buffer line, or the drawn line of a table hanging above the line after it.
local function top_position(state, view)
  for _, marks in pairs(state.marks) do
    local entry = marks.entry
    if entry.above then
      if view.topfill > 0 and view.topline == entry.last + 1 then
        return { entry = entry, index = #entry.virt - view.topfill + 1 }
      end
      if state.split == entry and view.topline == state.split_lnum then
        local from = span_of(entry, state.split_lnum)
        return { entry = entry, index = from - view.topfill }
      end
    end
  end
  return { topline = view.topline, topfill = view.topfill }
end

-- The view whose top shows the same thing as position under the current split. The drawn
-- lines shown above the top line are capped by what fits above it in the window.
local function view_at(win, state, position)
  local entry = position.entry
  local view
  if not entry then
    view = { topline = position.topline, topfill = position.topfill }
  elseif state.split == entry then
    local from = span_of(entry, state.split_lnum)
    -- A top at or below the rows now shown as the source line leaves the cursor at the top.
    view = { topline = state.split_lnum, topfill = math.max(0, from - position.index) }
  else
    view = { topline = entry.last + 1, topfill = #entry.virt - position.index + 1 }
  end

  if view.topfill > 0 then
    local ok, size = pcall(vim.api.nvim_win_text_height, win, {
      start_row = view.topline - 1,
      end_row = view.topline - 1,
    })
    local rows = ok and size.all - size.fill or 1
    view.topfill = math.max(0, math.min(view.topfill, vim.api.nvim_win_get_height(win) - rows))
  end
  return view
end

local function remember_view(win)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  views[win] = { topline = view.topline, topfill = view.topfill }
end

-- A window whose first line is hidden by conceal_lines, with none of the virtual lines
-- above it shown (topfill 0), is drawn wrongly by Neovim: once the cursor moves, the
-- cursor line appears twice and the line above it drops off the screen. Scrolling can
-- still pass through that position, so it is replaced by one that shows the same screen,
-- or the next one in the direction of the scroll.
local function settle_topline(win)
  local state = windows[win]
  if not state or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local previous = toplines[win]
  toplines[win] = view.topline
  if view.topfill ~= 0 then
    return
  end

  for _, marks in pairs(state.marks) do
    local entry = marks.entry
    if view.topline >= entry.first and view.topline <= entry.last and view.topline ~= view.lnum then
      local up = previous ~= nil and previous > view.topline
      local cursor_inside = view.lnum >= entry.first and view.lnum <= entry.last
      local target
      if cursor_inside and not up then
        -- The cursor line is the only source line shown. When the table hangs above the
        -- line after it, the drawn rows before the cursor hang above the cursor line, and
        -- showing as many of them as fit keeps the cursor at the bottom where scrolling
        -- down left it.
        local filler = 0
        if entry.above then
          local from = span_of(entry, view.lnum)
          local ok, size = pcall(vim.api.nvim_win_text_height, win, {
            start_row = view.lnum - 1,
            end_row = view.lnum - 1,
          })
          local rows = ok and size.all - size.fill or 1
          filler = math.max(0, math.min(from - 1, vim.api.nvim_win_get_height(win) - rows))
        end
        target = { topline = view.lnum, topfill = filler }
      elseif entry.above then
        if up and entry.first > 1 then
          target = { topline = entry.first - 1, topfill = 0 }
        else
          target = { topline = entry.last + 1, topfill = #entry.virt }
        end
      elseif up then
        target = { topline = view.topline, topfill = 1 }
      elseif cursor_inside then
        target = { topline = view.lnum, topfill = 0 }
      end
      if target then
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview(target)
        end)
        toplines[win] = target.topline
      end
      return
    end
  end
end

-- Splitting has to happen within the cursor movement: until it does, the rows after the
-- cursor hang off a line that is concealed again and are not drawn.
local function follow_cursor(win)
  local state = windows[win]
  if not state or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local marks = nil
  for _, candidate in pairs(state.marks) do
    if lnum >= candidate.entry.first and lnum <= candidate.entry.last then
      marks = candidate
      break
    end
  end
  local entry = marks and marks.entry
  if state.split == entry and (not entry or state.split_lnum == lnum) then
    return
  end

  -- Neovim scrolls for a cursor movement before the table is split around the new cursor
  -- line, as if the drawn rows were still where they hung before. Keeping what the top of
  -- the window showed before the movement lets the next redraw scroll only as far as the
  -- new layout needs.
  local position = views[win] and top_position(state, views[win])

  local ns = ns_for(win)
  if state.split and state.split ~= entry then
    join(state.bufnr, ns, state.split, state.marks[state.split.first])
  end
  if entry then
    split_at(state.bufnr, ns, entry, marks, lnum)
  end
  state.split, state.split_lnum = entry, lnum

  if position then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(view_at(win, state, position))
    end)
  end
end

-- A window that is not the current one conceals its cursor line like any other, so the
-- rows hanging above it would not be drawn there.
local function unsplit(win)
  local state = windows[win]
  if state and state.split then
    join(state.bufnr, ns_for(win), state.split, state.marks[state.split.first])
    state.split, state.split_lnum = nil, nil
  end
end

local function refresh(bufnr)
  if not config.get().enabled or vim.b[bufnr].md_table_wrap_disabled then
    clear_buffer(bufnr)
    return
  end

  local current = vim.api.nvim_get_current_win()
  for _, win in ipairs(buffer_windows(bufnr)) do
    if not renderable(win) then
      clear_window(win)
    else
      local layout = layout_for(bufnr, text_width(win))
      local state = windows[win]
      if not state or state.layout ~= layout then
        draw_window(win, bufnr, layout)
        invalidate(bufnr)
      end
      if win == current then
        follow_cursor(win)
      else
        unsplit(win)
      end
      settle_topline(win)
      remember_view(win)
    end
  end
end

local function schedule(bufnr)
  local timer = timers[bufnr]
  if not timer then
    timer = vim.uv.new_timer()
    timers[bufnr] = timer
  end
  timer:stop()
  timer:start(
    config.get().debounce,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        refresh(bufnr)
      end
    end)
  )
end

local function forget_window(win)
  clear_window(win)
  namespaces[win] = nil
  toplines[win] = nil
  views[win] = nil
end

local function detach(bufnr)
  local timer = timers[bufnr]
  if timer then
    timer:stop()
    timer:close()
    timers[bufnr] = nil
  end
  attached[bufnr] = nil
  clear_buffer(bufnr)
end

-- Right after a buffer opens other plugins have not placed their signs yet, so the gutter
-- width, and with it the space left for the table, is not settled. A redraw costs nothing
-- while the measurement is unchanged, so the width is re-checked for a moment after the
-- buffer appears.
local function settle(bufnr)
  local interval = 100
  local remaining = math.max(1, math.ceil(config.get().settle_time / interval))
  local timer = vim.uv.new_timer()
  -- Ticks already handed to the main loop still run after the timer is closed.
  timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if timer:is_closing() then
        return
      end
      remaining = remaining - 1
      local valid = vim.api.nvim_buf_is_valid(bufnr)
      if valid then
        refresh(bufnr)
      end
      if remaining <= 0 or not valid then
        timer:stop()
        timer:close()
      end
    end)
  )
end

local function attach(bufnr)
  if attached[bufnr] then
    return
  end
  attached[bufnr] = true

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = GROUP,
    buffer = bufnr,
    callback = function()
      enable_conceal(bufnr, { vim.api.nvim_get_current_win() })
      schedule(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorHold", "TextChanged", "WinEnter" }, {
    group = GROUP,
    buffer = bufnr,
    callback = function()
      schedule(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = GROUP,
    buffer = bufnr,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      follow_cursor(win)
      settle_topline(win)
      remember_view(win)
    end,
  })
  -- Entering insert mode has to take effect before the debounce elapses, or the source
  -- lines and the virtual ones show together. Clearing runs on the next tick rather than
  -- inside the mode change, so the screen is not rebuilt mid transition.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = GROUP,
    buffer = bufnr,
    callback = function()
      vim.schedule(function()
        local win = vim.api.nvim_get_current_win()
        if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_win_get_buf(win) == bufnr and not renderable(win) then
          clear_buffer(bufnr)
        end
      end)
      schedule(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = GROUP,
    buffer = bufnr,
    callback = function()
      unsplit(vim.api.nvim_get_current_win())
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = GROUP,
    buffer = bufnr,
    callback = function()
      detach(bufnr)
    end,
  })

  enable_conceal(bufnr)
  schedule(bufnr)
  settle(bufnr)
end

local function refresh_all()
  for bufnr in pairs(attached) do
    layouts[bufnr] = nil
    for win, state in pairs(windows) do
      if state.bufnr == bufnr then
        state.layout = nil
      end
    end
    schedule(bufnr)
  end
end

--- Turns the rendering for the current buffer on or off.
function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.b[bufnr].md_table_wrap_disabled = not vim.b[bufnr].md_table_wrap_disabled
  clear_buffer(bufnr)
  enable_conceal(bufnr)
  refresh(bufnr)
end

--- Turns the rendering on for every attached buffer.
function M.enable()
  config.get().enabled = true
  for bufnr in pairs(attached) do
    enable_conceal(bufnr)
  end
  refresh_all()
end

--- Turns the rendering off for every attached buffer.
function M.disable()
  config.get().enabled = false
  for bufnr in pairs(attached) do
    clear_buffer(bufnr)
  end
end

--- Opens the table under the cursor in a floating window.
M.open_float = float.open

function M.setup(opts)
  config.setup(opts)
  parser.clear_cache()

  -- A buffer is watched by autocmds of its own in this group, so clearing the group
  -- leaves every attached buffer unwatched until it is attached again.
  vim.api.nvim_clear_autocmds({ group = GROUP })
  for bufnr in pairs(attached) do
    attached[bufnr] = nil
  end
  vim.api.nvim_create_user_command("MdTableWrap", M.toggle, { desc = "Toggle wrapped table rendering" })
  vim.api.nvim_create_user_command("MdTableWrapFloat", M.open_float, {
    desc = "Open the table under the cursor in a floating window",
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = GROUP,
    pattern = config.get().filetypes,
    callback = function(args)
      attach(args.buf)
    end,
  })

  -- Settling cannot wait for the debounce: the next cursor movement would already be
  -- drawn from the broken position.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = GROUP,
    callback = function()
      for key in pairs(vim.v.event) do
        local win = tonumber(key)
        if win and windows[win] then
          settle_topline(win)
          remember_view(win)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = GROUP,
    callback = function(args)
      forget_window(tonumber(args.match))
    end,
  })

  -- A resize changes the width available to every window, not just the current one.
  vim.api.nvim_create_autocmd("WinResized", {
    group = GROUP,
    callback = refresh_all,
  })

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.tbl_contains(config.get().filetypes, vim.bo[bufnr].filetype) then
      attach(bufnr)
    end
  end
end

-- Exposed for the tests.
M._settle_topline = settle_topline
M._top_position = top_position
M._view_at = view_at
M._namespace_for = ns_for
M._state_for = function(win)
  return windows[win]
end

return M

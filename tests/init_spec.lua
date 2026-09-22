describe("md-table-wrap", function()
  local plugin

  local function fresh()
    for _, name in ipairs({ "", ".config", ".float", ".parser", ".render", ".text" }) do
      package.loaded["md-table-wrap" .. name] = nil
    end
    return require("md-table-wrap")
  end

  local function open(lines)
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.wo.conceallevel = 2
    vim.bo.filetype = "markdown"
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    return vim.api.nvim_get_current_buf()
  end

  local function marks(bufnr, win)
    local ns = plugin._namespace_for(win or vim.api.nvim_get_current_win())
    return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  end

  local function wait_for_marks(bufnr, expected)
    vim.wait(2000, function()
      return #marks(bufnr) == expected
    end, 20)
    return marks(bufnr)
  end

  local table_lines = { "intro", "| a | b |", "|---|---|", "| 1 | 2 |", "outro" }

  before_each(function()
    plugin = fresh()
    plugin.setup({ debounce = 10, settle_time = 100 })
  end)

  after_each(function()
    pcall(vim.api.nvim_del_user_command, "MdTableWrap")
    pcall(vim.api.nvim_del_user_command, "MdTableWrapFloat")
  end)

  it("registers the toggle command", function()
    assert.is_not_nil(vim.api.nvim_get_commands({})["MdTableWrap"])
  end)

  it("conceals the source and draws virtual lines", function()
    local bufnr = open(table_lines)
    local found = wait_for_marks(bufnr, 2)
    assert.are.equal(2, #found)

    local conceal, virt
    for _, mark in ipairs(found) do
      conceal = mark[4].conceal_lines and mark or conceal
      virt = mark[4].virt_lines and mark or virt
    end
    assert.is_not_nil(conceal)
    assert.is_not_nil(virt)
    assert.are.equal(1, conceal[2]) -- second line, zero based
    assert.are.equal(3, conceal[4].end_row)
    assert.are.equal(4, virt[2]) -- hangs above the line after the table
    assert.is_true(virt[4].virt_lines_above)
    assert.are.equal(5, #virt[4].virt_lines)
  end)

  local function virt_counts(bufnr)
    local counts = {}
    for _, mark in ipairs(marks(bufnr)) do
      if mark[4].virt_lines then
        counts[mark[2]] = { #mark[4].virt_lines, mark[4].virt_lines_above or false }
      end
    end
    return counts
  end

  it("shows the source of the cursor line in place of its drawn row", function()
    local bufnr = open(table_lines)
    wait_for_marks(bufnr, 2)
    vim.api.nvim_win_set_cursor(0, { 4, 0 }) -- the data row
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })

    -- rows above the cursor hang above the cursor line, the rest above the line after the table
    assert.are.same({ [3] = { 3, true }, [4] = { 1, true } }, virt_counts(bufnr))
  end)

  it("joins the table back when the cursor leaves it", function()
    local bufnr = open(table_lines)
    wait_for_marks(bufnr, 2)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })

    assert.are.same({ [4] = { 5, true } }, virt_counts(bufnr))
  end)

  it("splits a table that ends the buffer the other way round", function()
    local bufnr = open({ "intro", "| a | b |", "|---|---|", "| 1 | 2 |" })
    wait_for_marks(bufnr, 2)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })

    -- rows above the cursor hang below the line before the table, the rest below the cursor line
    assert.are.same({ [0] = { 3, false }, [3] = { 1, false } }, virt_counts(bufnr))
  end)

  -- The same guard hides the table in insert mode, which tests/screen_spec.lua covers
  -- by typing into a second Neovim.
  it("removes the virtual lines when conceal is off", function()
    local bufnr = open(table_lines)
    wait_for_marks(bufnr, 2)
    vim.wo.conceallevel = 0
    vim.api.nvim_exec_autocmds("ModeChanged", { buffer = bufnr })
    assert.are.equal(0, #wait_for_marks(bufnr, 0))
    -- a renderer lowers the level on purpose, so it is not raised back
    assert.are.equal(0, vim.wo.conceallevel)
  end)

  describe("conceallevel", function()
    local function open_with_level(level)
      vim.cmd("enew!")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, table_lines)
      vim.wo.conceallevel = level
      vim.bo.filetype = "markdown"
      return vim.api.nvim_get_current_buf()
    end

    it("turns conceal on in a window that has it off", function()
      local bufnr = open_with_level(0)
      assert.are.equal(2, vim.wo.conceallevel)
      assert.are.equal(2, #wait_for_marks(bufnr, 2))
    end)

    it("keeps a level that is already above 0", function()
      open_with_level(3)
      assert.are.equal(3, vim.wo.conceallevel)
    end)

    it("uses the configured level", function()
      plugin.setup({ debounce = 10, settle_time = 100, conceallevel = 1 })
      open_with_level(0)
      assert.are.equal(1, vim.wo.conceallevel)
    end)

    it("leaves conceal off when told not to touch it", function()
      plugin.setup({ debounce = 10, settle_time = 100, conceallevel = false })
      local bufnr = open_with_level(0)
      vim.wait(200)
      assert.are.equal(0, vim.wo.conceallevel)
      assert.are.equal(0, #marks(bufnr))
    end)

    it("turns conceal on once a buffer set up while hidden is shown", function()
      local bufnr = open_with_level(0)
      vim.wo.conceallevel = 0 -- the level the buffer is hidden with, and shown with again
      vim.bo[bufnr].bufhidden = "hide"
      vim.cmd("enew")
      plugin.setup({ debounce = 10, settle_time = 100 })

      vim.cmd("buffer " .. bufnr)
      assert.are.equal(2, vim.wo.conceallevel)
    end)

    it("turns conceal on when the buffer is rendered again after a toggle", function()
      local bufnr = open_with_level(0)
      wait_for_marks(bufnr, 2)
      vim.cmd("MdTableWrap")
      vim.wo.conceallevel = 0
      vim.cmd("MdTableWrap")
      assert.are.equal(2, vim.wo.conceallevel)
    end)
  end)

  it("toggles the current buffer", function()
    local bufnr = open(table_lines)
    wait_for_marks(bufnr, 2)
    plugin.toggle()
    assert.are.equal(0, #marks(bufnr))
    plugin.toggle()
    assert.are.equal(2, #wait_for_marks(bufnr, 2))
  end)

  it("disables and enables every buffer", function()
    local bufnr = open(table_lines)
    wait_for_marks(bufnr, 2)
    plugin.disable()
    assert.are.equal(0, #marks(bufnr))
    plugin.enable()
    assert.are.equal(2, #wait_for_marks(bufnr, 2))
  end)

  it("hangs the table below the line before it when it ends the buffer", function()
    local bufnr = open({ "intro", "| a | b |", "|---|---|", "| 1 | 2 |" })
    local found = wait_for_marks(bufnr, 2)
    local virt
    for _, mark in ipairs(found) do
      virt = mark[4].virt_lines and mark or virt
    end
    assert.are.equal(0, virt[2]) -- the line before the table, zero based
    assert.is_false(virt[4].virt_lines_above or false)
  end)

  it("leaves a table with no neighbouring line as source", function()
    local bufnr = open({ "| a | b |", "|---|---|", "| 1 | 2 |" })
    vim.wait(200)
    assert.are.equal(0, #marks(bufnr))
  end)

  local function drawn_width(bufnr, win)
    local width = 0
    for _, mark in ipairs(marks(bufnr, win)) do
      if mark[4].virt_lines then
        for _, chunk in ipairs(mark[4].virt_lines[1]) do
          width = width + vim.fn.strdisplaywidth(chunk[1])
        end
      end
    end
    return width
  end

  it("lays each window out for its own width", function()
    local bufnr = open({
      "intro",
      "| a | b |",
      "|---|---|",
      "| a long cell that needs plenty of room | another long cell that also needs room |",
      "outro",
    })
    wait_for_marks(bufnr, 2)
    local wide = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(wide, 60)
    vim.cmd("vsplit")
    local narrow = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(narrow, 24)
    vim.api.nvim_exec_autocmds("WinResized", {})
    vim.wait(400)

    assert.is_true(drawn_width(bufnr, narrow) <= 24, "narrow window is " .. drawn_width(bufnr, narrow) .. " wide")
    assert.is_true(drawn_width(bufnr, wide) > 24, "wide window is " .. drawn_width(bufnr, wide) .. " wide")
    vim.api.nvim_win_close(narrow, true)
    vim.api.nvim_set_current_win(wide)
  end)

  it("splits only the window the cursor is in", function()
    local bufnr = open(table_lines)
    wait_for_marks(bufnr, 2)
    local other = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local current = vim.api.nvim_get_current_win()
    vim.api.nvim_exec_autocmds("WinEnter", { buffer = bufnr })
    vim.wait(400)
    vim.api.nvim_win_set_cursor(current, { 4, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })

    -- the window with the cursor carries an extra mark for the rows after it
    assert.are.equal(3, #marks(bufnr, current))
    assert.are.equal(2, #marks(bufnr, other))
    local whole = 0
    for _, mark in ipairs(marks(bufnr, other)) do
      if mark[4].virt_lines then
        whole = #mark[4].virt_lines
      end
    end
    assert.are.equal(5, whole) -- the other window still draws the table in one piece
    vim.api.nvim_win_close(current, true)
    vim.api.nvim_set_current_win(other)
  end)

  it("does not rebuild extmarks when the cursor moves", function()
    local bufnr = open({
      "intro",
      "| a | b |",
      "|---|---|",
      "| 1 | 2 |",
      "between",
      "| c | d |",
      "|---|---|",
      "| 3 | 4 |",
      "end",
    })
    local function ids()
      return vim.tbl_map(function(mark)
        return mark[1]
      end, wait_for_marks(bufnr, 4))
    end

    local before = ids()
    for _, row in ipairs({ 3, 7, 9 }) do
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
      vim.wait(100)
    end
    assert.are.same(before, ids())
  end)

  -- Signs placed once the buffer is on screen change the room left for the table without
  -- any event the renderer listens for, so the width is re-measured for a while.
  it("re-measures the width after the buffer opens", function()
    plugin.setup({ debounce = 10, settle_time = 1000 })
    local bufnr = open({
      "intro",
      "| a | b |",
      "|---|---|",
      "| a long cell that needs plenty of room | another long cell that also needs room |",
      "outro",
    })
    wait_for_marks(bufnr, 2)
    local win = vim.api.nvim_get_current_win()
    local before = drawn_width(bufnr, win)

    vim.wo.number = true
    local ok = vim.wait(2000, function()
      return drawn_width(bufnr, win) < before
    end, 20)
    vim.wo.number = false
    assert.is_true(ok, "the table still measures " .. drawn_width(bufnr, win))
  end)

  it("keeps rendering a buffer that was open when setup ran again", function()
    local bufnr = open(table_lines)
    wait_for_marks(bufnr, 2)
    plugin.setup({ debounce = 10, settle_time = 100 })
    vim.wait(300) -- once the width has settled, only an autocmd can pick a change up

    vim.api.nvim_buf_set_lines(bufnr, 4, 4, false, { "| 3 | 4 |" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
    local ok = vim.wait(1000, function()
      for _, mark in ipairs(marks(bufnr)) do
        if mark[4].virt_lines and #mark[4].virt_lines == 6 then
          return true
        end
      end
      return false
    end, 20)
    assert.is_true(ok, "the added row was not drawn")
  end)

  describe("window top across splitting", function()
    -- table_lines holds a table on lines 2-4, drawn as five rows above line 5
    local function opened()
      local bufnr = open(table_lines)
      wait_for_marks(bufnr, 2)
      return bufnr, vim.api.nvim_get_current_win()
    end

    local function move_to(bufnr, lnum)
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
    end

    it("keeps a top that shows no part of a table", function()
      local _, win = opened()
      local state = plugin._state_for(win)
      local position = plugin._top_position(state, { topline = 1, topfill = 0 })
      assert.are.same({ topline = 1, topfill = 0 }, position)
      assert.are.same({ topline = 1, topfill = 0 }, plugin._view_at(win, state, position))
    end)

    it("follows a drawn row into the split around the cursor", function()
      local bufnr, win = opened()
      -- three of the five rows hang above line 5, so the top shows the third: the delimiter
      local position = plugin._top_position(plugin._state_for(win), { topline = 5, topfill = 3 })
      assert.are.equal(3, position.index)

      move_to(bufnr, 4) -- the data row, drawn fourth
      -- its three rows before hang above the source line, one of them above the top
      assert.are.same({ topline = 4, topfill = 1 }, plugin._view_at(win, plugin._state_for(win), position))
    end)

    it("finds the same drawn row again once the table is whole", function()
      local bufnr, win = opened()
      move_to(bufnr, 4)
      local position = plugin._top_position(plugin._state_for(win), { topline = 4, topfill = 1 })
      assert.are.equal(3, position.index)

      move_to(bufnr, 5)
      assert.are.same({ topline = 5, topfill = 3 }, plugin._view_at(win, plugin._state_for(win), position))
    end)

    it("shows no more rows above the top than the window has room for", function()
      local other = vim.api.nvim_get_current_win()
      vim.cmd("split")
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_height(win, 3)
      local bufnr = open(table_lines)
      wait_for_marks(bufnr, 2)

      local state = plugin._state_for(win)
      local position = plugin._top_position(state, { topline = 5, topfill = 5 })
      assert.are.equal(1, position.index)
      -- line 5 itself takes one of the three screen lines
      assert.are.same({ topline = 5, topfill = 2 }, plugin._view_at(win, state, position))

      vim.api.nvim_win_close(win, true)
      vim.api.nvim_set_current_win(other)
    end)
  end)

  it("keeps the cursor near where it was while moving through a table", function()
    local lines = {}
    for i = 1, 10 do
      lines[i] = "before " .. i
    end
    vim.list_extend(lines, { "| day | note |", "|---|---|" })
    for i = 1, 12 do
      table.insert(lines, ("| 9/%02d | a fairly long note number %d that wraps in a narrow column |"):format(i, i))
    end
    table.insert(lines, "")
    for i = 1, 20 do
      table.insert(lines, "after " .. i)
    end
    local bufnr = open(lines)
    wait_for_marks(bufnr, 2)

    local function walk(motion, steps)
      local jumps = {}
      local previous = vim.fn.winline()
      for _ = 1, steps do
        vim.cmd("normal! " .. motion)
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
        local current = vim.fn.winline()
        if math.abs(current - previous) > 4 then
          table.insert(jumps, ("line %d: %d -> %d"):format(vim.fn.line("."), previous, current))
        end
        previous = current
      end
      return jumps
    end

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    assert.are.same({}, walk("j", 30))
    assert.are.same({}, walk("k", 30))
  end)

  describe("window whose first line is hidden", function()
    -- rows 1-30 filler, table 32-34, rows 36-70 filler
    local function open_long()
      local lines = {}
      for i = 1, 30 do
        lines[i] = "before " .. i
      end
      vim.list_extend(lines, { "", "| a | b |", "|---|---|", "| 1 | 2 |", "" })
      for i = 1, 35 do
        table.insert(lines, "after " .. i)
      end
      local bufnr = open(lines)
      vim.api.nvim_win_set_cursor(0, { 60, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
      wait_for_marks(bufnr, 2)
      return bufnr
    end

    local function view()
      local v = vim.fn.winsaveview()
      return { topline = v.topline, topfill = v.topfill }
    end

    it("moves above the table when scrolling up into it", function()
      local bufnr = open_long()
      local win = vim.api.nvim_get_current_win()
      vim.fn.winrestview({ topline = 40, topfill = 0 })
      plugin._settle_topline(win)
      vim.fn.winrestview({ topline = 34, topfill = 0 })
      plugin._settle_topline(win)
      assert.are.same({ topline = 31, topfill = 0 }, view())
    end)

    it("shows the whole table above the line after it otherwise", function()
      local bufnr = open_long()
      local win = vim.api.nvim_get_current_win()
      vim.fn.winrestview({ topline = 20, topfill = 0 })
      plugin._settle_topline(win)
      vim.fn.winrestview({ topline = 33, topfill = 0 })
      plugin._settle_topline(win)
      assert.are.same({ topline = 35, topfill = 5 }, view())
    end)

    it("starts at the cursor line when the cursor is inside the table", function()
      local bufnr = open_long()
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(0, { 34, 0 }) -- the data row
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
      vim.fn.winrestview({ topline = 20, topfill = 0 })
      plugin._settle_topline(win)
      vim.fn.winrestview({ topline = 32, topfill = 0 })
      plugin._settle_topline(win)
      -- top border, header and delimiter hang above the cursor line
      assert.are.same({ topline = 34, topfill = 3 }, view())
    end)

    it("leaves a window that starts at the cursor line alone", function()
      local bufnr = open_long()
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(0, { 33, 0 })
      vim.fn.winrestview({ topline = 33, topfill = 0 })
      plugin._settle_topline(win)
      assert.are.same({ topline = 33, topfill = 0 }, view())
    end)

    it("leaves a window that starts outside every table alone", function()
      local bufnr = open_long()
      local win = vim.api.nvim_get_current_win()
      vim.fn.winrestview({ topline = 35, topfill = 2 })
      plugin._settle_topline(win)
      assert.are.same({ topline = 35, topfill = 2 }, view())
    end)
  end)

  it("ignores buffers of other filetypes", function()
    vim.cmd("enew!")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, table_lines)
    vim.bo.filetype = "text"
    local bufnr = vim.api.nvim_get_current_buf()
    vim.wait(100)
    assert.are.equal(0, #marks(bufnr))
  end)

  describe("floating window", function()
    local long_lines = {
      "intro",
      "| n | note |",
      "|---|---|",
      "| 1 | **bold** text |",
      "| 2 | another |",
      "outro",
    }

    it("shows the table under the cursor as buffer text, on the row of the cursor", function()
      open(long_lines)
      local source = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      vim.cmd("MdTableWrapFloat")

      local win = vim.api.nvim_get_current_win()
      assert.are_not.equal(source, win)
      assert.are.equal("editor", vim.api.nvim_win_get_config(win).relative)
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert.are.equal("┌", vim.fn.strcharpart(lines[1], 0, 1))
      assert.is_truthy(vim.api.nvim_get_current_line():find("│ 2 │", 1, true))
      assert.is_truthy(table.concat(lines, "\n"):find("bold text", 1, true))
      assert.is_false(vim.bo.modifiable)

      vim.api.nvim_feedkeys("q", "x", false)
      assert.is_false(vim.api.nvim_win_is_valid(win))
      assert.are.equal(source, vim.api.nvim_get_current_win())
    end)

    it("highlights the styled text of a cell", function()
      open(long_lines)
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      plugin.open_float()
      local found = vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })
      local styled = vim.tbl_filter(function(mark)
        local hl = mark[4].hl_group
        return hl and vim.inspect(hl):find("strong", 1, true)
      end, found)
      assert.are.equal(1, #styled)
      vim.cmd("close")
    end)

    it("closes when another window is entered", function()
      open(long_lines)
      local source = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      local win = plugin.open_float()
      vim.api.nvim_set_current_win(source)
      vim.wait(200, function()
        return not vim.api.nvim_win_is_valid(win)
      end, 10)
      assert.is_false(vim.api.nvim_win_is_valid(win))
    end)

    it("opens nothing outside a table", function()
      open(long_lines)
      local source = vim.api.nvim_get_current_win()
      assert.is_nil(plugin.open_float())
      assert.are.equal(source, vim.api.nvim_get_current_win())
    end)
  end)
end)

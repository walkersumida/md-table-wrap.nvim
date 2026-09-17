-- Drawing a table replaces buffer lines with virtual ones, which only a real screen can
-- show. These tests drive a second Neovim in a pty and read its screen over RPC, so that
-- what the terminal ends up with is checked, not just the extmarks behind it.

local CAPTURE = [[
  local rows = {}
  -- the last screen line carries messages, not the window
  for row = 1, vim.o.lines - 1 do
    local cells = {}
    for col = 1, vim.o.columns do
      cells[#cells + 1] = vim.fn.screenstring(row, col)
    end
    rows[#rows + 1] = (table.concat(cells):gsub("%s+$", ""))
  end
  return rows
]]

describe("md-table-wrap on screen", function()
  local repo = vim.fn.getcwd()
  local children = 0

  local Child = {}
  Child.__index = Child

  function Child:eval(code)
    return vim.rpcrequest(self.chan, "nvim_exec_lua", code, {})
  end

  function Child:input(keys)
    vim.rpcrequest(self.chan, "nvim_input", keys)
  end

  function Child:mode()
    return vim.rpcrequest(self.chan, "nvim_get_mode").mode
  end

  function Child:screen()
    return self:eval(CAPTURE)
  end

  function Child:wait(predicate, message)
    local last
    local ok = vim.wait(3000, function()
      last = predicate(self)
      return last and true or false
    end, 20)
    assert.is_true(ok, message .. ", screen:\n" .. table.concat(self:screen(), "\n"))
    return last
  end

  function Child:stop()
    pcall(vim.fn.chanclose, self.chan)
    vim.fn.jobstop(self.job)
    os.remove(self.file)
    os.remove(self.sock)
  end

  local function start(lines, opts)
    opts = opts or {}
    children = children + 1
    local child = setmetatable({
      file = vim.fn.tempname() .. ".md",
      -- a socket path has to stay well under the length a unix socket allows
      sock = ("/tmp/md-table-wrap-%d-%d.sock"):format(vim.fn.getpid(), children),
    }, Child)
    vim.fn.writefile(lines, child.file)
    os.remove(child.sock)

    child.job = vim.fn.jobstart({
      vim.v.progpath,
      "--clean",
      "-n",
      "--listen",
      child.sock,
      "--cmd",
      "set rtp+=" .. repo,
      "--cmd",
      ("set conceallevel=%d concealcursor= laststatus=0 noruler noshowcmd noshowmode"):format(
        opts.conceallevel or 2
      ),
      "-c",
      "lua require('md-table-wrap').setup({ debounce = 10, settle_time = 100 })",
      child.file,
    }, { pty = true, width = opts.width or 50, height = opts.height or 12 })
    assert.is_true(child.job > 0, "could not start a second Neovim")

    vim.wait(5000, function()
      local ok, chan = pcall(vim.fn.sockconnect, "pipe", child.sock, { rpc = true })
      if ok and chan ~= 0 then
        child.chan = chan
      end
      return child.chan ~= nil
    end, 50)
    assert.is_not_nil(child.chan, "the second Neovim did not listen on its socket")
    return child
  end

  local function contains(screen, pattern)
    for _, row in ipairs(screen) do
      if row:find(pattern) then
        return true
      end
    end
    return false
  end

  local function drawn(child)
    return contains(child:screen(), "│")
  end

  local table_lines = {
    "intro",
    "| n | note |",
    "|---|---|",
    "| 1 | a note that is long enough to wrap in a narrow column |",
    "| 2 | another note of about the same generous length |",
    "outro",
  }

  it("draws the table over its source lines", function()
    local child = start(table_lines)
    child:wait(drawn, "the table was never drawn")
    local screen = child:screen()
    assert.is_false(contains(screen, "|%-%-%-|"), "the source delimiter row is still on screen")
    assert.is_true(contains(screen, "wrap in a"), "the wrapped cell is missing")
    child:stop()
  end)

  it("draws the table in a Neovim that starts with conceal off", function()
    local child = start(table_lines, { conceallevel = 0 })
    child:wait(drawn, "the table was never drawn")
    child:stop()
  end)

  it("shows the source of the line being edited and draws again on escape", function()
    local child = start(table_lines)
    child:wait(drawn, "the table was never drawn")
    child:eval("vim.api.nvim_win_set_cursor(0, { 4, 0 })")

    child:input("i")
    child:wait(function(c)
      return c:mode() == "i"
    end, "the second Neovim did not enter insert mode")
    child:wait(function(c)
      return not drawn(c)
    end, "the table is still drawn while inserting")
    assert.is_true(contains(child:screen(), "|%-%-%-|"), "the source is not shown while inserting")

    child:input("<Esc>")
    child:wait(function(c)
      return c:mode() == "n"
    end, "the second Neovim stayed in insert mode")
    child:wait(drawn, "the table was not drawn again after leaving insert mode")
    child:stop()
  end)

  it("shows the cursor row as source inside the drawn table", function()
    local child = start(table_lines)
    child:wait(drawn, "the table was never drawn")
    child:eval("vim.api.nvim_win_set_cursor(0, { 4, 0 })")
    local screen = child:wait(function(c)
      local rows = c:screen()
      return contains(rows, "^| 1 |") and rows
    end, "the cursor row is not shown as source")
    assert.is_true(contains(screen, "│"), "the rest of the table is not drawn")
    assert.is_false(contains(screen, "^| 2 |"), "another row is shown as source as well")
    child:stop()
  end)

  -- Scrolling a concealed range with virtual lines around it has repeatedly made Neovim
  -- draw a line twice, or drop the line above the cursor. The surrounding lines are
  -- numbered, so a screen that has lost one, or shows one twice, is a broken screen.
  local function faults(screen)
    local found, seen, previous = {}, {}, nil
    for row, line in ipairs(screen) do
      if line ~= "" and line ~= "~" and line == screen[row - 1] then
        table.insert(found, ("row %d repeats %q"):format(row, line))
      end
      local kind, number = line:match("^(%a+) (%d+)$")
      if kind then
        if seen[line] then
          table.insert(found, ("%q is on rows %d and %d"):format(line, seen[line], row))
        end
        seen[line] = row
        number = tonumber(number)
        if previous and previous.kind == kind and number ~= previous.number + 1 then
          table.insert(found, ("%s %d is followed by %d"):format(kind, previous.number, number))
        end
        previous = { kind = kind, number = number }
      end
    end
    return found
  end

  it("keeps every line on screen while scrolling past a table", function()
    local lines = {}
    for i = 1, 20 do
      lines[i] = "before " .. i
    end
    vim.list_extend(lines, table_lines)
    for i = 1, 20 do
      table.insert(lines, "after " .. i)
    end
    local child = start(lines)
    child:wait(function(c)
      return c:eval("return #vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {})") > 0
    end, "the table was never drawn")

    local broken = {}
    local function step(keys, what)
      child:input(keys)
      vim.wait(80)
      local screen = child:screen()
      local found = faults(screen)
      if #found > 0 then
        local where = child:eval("local v = vim.fn.winsaveview() return v.topline .. ' ' .. v.topfill .. ' ' .. vim.fn.line('.')")
        table.insert(
          broken,
          ("%s (topline topfill cursor: %s): %s\n%s"):format(what, where, table.concat(found, ", "), table.concat(screen, "\n"))
        )
      end
    end

    child:eval("vim.api.nvim_win_set_cursor(0, { 34, 0 })")
    for i = 1, 22 do
      step("k", "moving up " .. i)
    end
    for i = 1, 22 do
      step("j", "moving down " .. i)
    end
    for i = 1, 14 do
      step("<C-y>", "scrolling up " .. i)
    end
    for i = 1, 14 do
      step("<C-e>", "scrolling down " .. i)
    end
    child:stop()
    assert.are.equal("", table.concat(broken, "\n\n"))
  end)
end)

describe("md-table-wrap.render", function()
  local parser, render, text

  before_each(function()
    for _, name in ipairs({ "config", "parser", "render", "text" }) do
      package.loaded["md-table-wrap." .. name] = nil
    end
    parser = require("md-table-wrap.parser")
    render = require("md-table-wrap.render")
    text = require("md-table-wrap.text")
  end)

  local function build(lines, budget)
    local header, rows = parser.rows(lines, 1, #lines)
    return render.build(header, rows, budget)
  end

  local function line_width(chunks)
    local width = 0
    for _, chunk in ipairs(chunks) do
      width = width + text.width(chunk[1])
    end
    return width
  end

  local function joined(chunks)
    local parts = {}
    for _, chunk in ipairs(chunks) do
      table.insert(parts, chunk[1])
    end
    return table.concat(parts)
  end

  it("gives every line the same display width", function()
    local lines = {
      "| 見出し | 説明 |",
      "|---|---|",
      "| `min_col_width` | 列を詰めるときの下限。これ以上は狭くならない |",
      "| `debounce` | イベントから再描画までの待ち時間（ミリ秒） |",
    }
    for budget = 30, 120, 3 do
      local widths = {}
      for _, chunks in ipairs(build(lines, budget)) do
        widths[line_width(chunks)] = true
      end
      assert.are.equal(1, vim.tbl_count(widths), "budget " .. budget)
    end
  end)

  it("stays within the budget when it can", function()
    local lines = { "| a | b |", "|---|---|", "| 1 | 2 |" }
    for _, chunks in ipairs(build(lines, 60)) do
      assert.is_true(line_width(chunks) <= 60)
    end
  end)

  it("draws borders and the header", function()
    local out = build({ "| a | b |", "|---|---|", "| 1 | 2 |" }, 40)
    assert.are.equal("┌───┬───┐", joined(out[1]))
    assert.are.equal("│ a │ b │", joined(out[2]))
    assert.are.equal("├───┼───┤", joined(out[3]))
    assert.are.equal("│ 1 │ 2 │", joined(out[4]))
    assert.are.equal("└───┴───┘", joined(out[5]))
  end)

  it("separates rows once a cell wraps", function()
    local lines = {
      "| a | b |",
      "|---|---|",
      "| 1 | one two three four five |",
      "| 2 | six |",
    }
    local rules = 0
    for _, chunks in ipairs(build(lines, 26)) do
      if joined(chunks):match("^├") then
        rules = rules + 1
      end
    end
    assert.are.equal(2, rules)
  end)

  it("highlights the header and inline code", function()
    local out = build({ "| head |", "|---|", "| `code` |" }, 40)
    local header_hl, code_hl
    for _, chunk in ipairs(out[2]) do
      if chunk[1]:match("head") then
        header_hl = chunk[2]
      end
    end
    for _, chunk in ipairs(out[4]) do
      if chunk[1]:match("code") then
        code_hl = chunk[2]
      end
    end
    assert.are.same({ "Title" }, header_hl)
    assert.are.same({ "@markup.raw.markdown_inline", "RenderMarkdownCodeInline" }, code_hl)
  end)

  it("keeps the columns aligned around an emoji", function()
    local warn = "⚠\239\184\143"
    local lines = {
      "| a | b |",
      "|---|---|",
      "| " .. warn .. " 注意 | " .. warn .. " そのまま入れると巻き戻る（下記）。" .. warn .. " |",
      "| 1 | 家族 👨‍👩‍👦 と 👍🏽 と 🇯🇵 |",
    }
    for budget = 20, 60, 2 do
      local widths = {}
      for _, chunks in ipairs(build(lines, budget)) do
        widths[line_width(chunks)] = true
      end
      assert.are.equal(1, vim.tbl_count(widths), "budget " .. budget)
    end
  end)

  it("keeps a cell broken by <br> on separate lines", function()
    local out = build({ "| a |", "|---|", "| one<br>two |" }, 40)
    assert.are.equal("│ one │", joined(out[4]))
    assert.are.equal("│ two │", joined(out[5]))
  end)

  it("draws an escaped pipe as a pipe", function()
    local out = build({ "| a |", "|---|", "| x\\|y |" }, 40)
    assert.are.equal("│ x|y │", joined(out[4]))
  end)

  it("pads a row that has fewer cells than the header", function()
    local out = build({ "| a | b |", "|---|---|", "| 1 |" }, 40)
    assert.are.equal("│ 1 │   │", joined(out[4]))
  end)

  it("reports which drawn lines stand for each row", function()
    local header, rows = parser.rows({ "| a |", "|---|", "| one<br>two |", "| three |" }, 1, 4)
    local lines, ranges = render.build(header, rows, 40)
    assert.are.same({ 2, 2 }, ranges.header)
    assert.are.same({ 3, 3 }, ranges.delimiter)
    assert.are.same({ { 4, 5 }, { 7, 7 } }, ranges.rows) -- a rule separates wrapped rows
    assert.are.equal(8, #lines)
  end)

  it("does not squeeze a column below min_col_width", function()
    local config = require("md-table-wrap.config")
    config.setup({ min_col_width = 10 })
    local lines = {
      "| " .. string.rep("a", 40) .. " | " .. string.rep("b", 40) .. " |",
      "|---|---|",
      "| 1 | 2 |",
    }
    local widest = 0
    for _, chunks in ipairs(build(lines, 20)) do
      widest = math.max(widest, line_width(chunks))
    end
    -- two columns of ten plus borders and padding
    assert.are.equal(27, widest)
  end)
end)

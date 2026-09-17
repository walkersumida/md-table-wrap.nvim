describe("md-table-wrap.parser", function()
  local parser

  before_each(function()
    package.loaded["md-table-wrap.parser"] = nil
    package.loaded["md-table-wrap.config"] = nil
    parser = require("md-table-wrap.parser")
    parser.clear_cache()
  end)

  describe("split_cells", function()
    it("splits on unescaped pipes only", function()
      assert.are.same({ "a", "b|c", "d" }, parser.split_cells("| a | b\\|c | d |"))
    end)

    it("trims each cell", function()
      assert.are.same({ "a", "b" }, parser.split_cells("|   a   |  b |"))
    end)
  end)

  describe("is_delimiter_row", function()
    it("accepts alignment markers", function()
      assert.is_true(parser.is_delimiter_row({ "---", ":--", "--:", ":-:" }))
    end)

    it("rejects content rows", function()
      assert.is_false(parser.is_delimiter_row({ "---", "a" }))
    end)
  end)

  describe("clean_cell", function()
    it("turns <br> into a newline", function()
      assert.are.equal("a\nb", parser.clean_cell("a<br>b"))
      assert.are.equal("a\nb", parser.clean_cell("a<br/>b"))
    end)

    it("drops variation selectors", function()
      assert.are.equal("⚠ 注意", parser.clean_cell("⚠\239\184\143 注意"))
    end)
  end)

  describe("parse_inline", function()
    it("drops emphasis and code markers", function()
      local plain = parser.parse_inline("**bold** and `code`")
      assert.are.equal("bold and code", plain)
    end)

    it("highlights the characters of a code span", function()
      local plain, styles = parser.parse_inline("x `ab`")
      assert.are.equal("x ab", plain)
      assert.is_nil(styles[1])
      assert.are.same({ "@markup.raw.markdown_inline", "RenderMarkdownCodeInline" }, styles[3])
    end)

    it("keeps asterisks that live inside a code span", function()
      assert.are.equal("a**b**c", parser.parse_inline("`a**b**c`"))
    end)

    it("combines nested styles", function()
      local plain, styles = parser.parse_inline("**a `b`**")
      assert.are.equal("a b", plain)
      assert.are.same({ "@markup.strong" }, styles[1])
      assert.are.same(
        { "@markup.strong", "@markup.raw.markdown_inline", "RenderMarkdownCodeInline" },
        styles[3]
      )
    end)

    it("leaves plain text untouched", function()
      local plain, styles = parser.parse_inline("no markup here")
      assert.are.equal("no markup here", plain)
      assert.is_nil(styles)
    end)
  end)

  describe("find_tables", function()
    it("finds each run of table lines", function()
      local lines = { "intro", "| a | b |", "|---|---|", "| 1 | 2 |", "between", "| c |", "|---|" }
      assert.are.same({ { first = 2, last = 4 }, { first = 6, last = 7 } }, parser.find_tables(lines))
    end)

    it("skips pipes inside fenced code blocks", function()
      local lines = {
        "```markdown",
        "| not | a table |",
        "|---|---|",
        "```",
        "| real | table |",
        "|---|---|",
        "| 1 | 2 |",
      }
      local tables = parser.find_tables(lines)
      assert.are.same({ { first = 5, last = 7 } }, tables)
    end)
  end)

  describe("rows", function()
    it("skips the delimiter row and parses each cell", function()
      local lines = { "| **h** | b |", "|---|---|", "| `x` | y |" }
      local header, rows = parser.rows(lines, 1, 3)
      assert.are.equal("h", header[1].text)
      assert.are.equal(1, #rows)
      assert.are.equal("x", rows[1][1].text)
      assert.are.equal("y", rows[1][2].text)
    end)

    it("reports the buffer line of each row", function()
      local lines = { "intro", "| h |", "|---|", "| 1 |", "| 2 |" }
      local _, _, lnums = parser.rows(lines, 2, 5)
      assert.are.same({ header = 2, delimiter = 3, rows = { 4, 5 } }, lnums)
    end)

    it("returns no rows for a header without data", function()
      local _, rows = parser.rows({ "| a |", "|---|" }, 1, 2)
      assert.are.equal(0, #rows)
    end)
  end)
end)

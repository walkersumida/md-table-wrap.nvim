describe("md-table-wrap.text", function()
  local text

  before_each(function()
    package.loaded["md-table-wrap.text"] = nil
    text = require("md-table-wrap.text")
  end)

  local function texts(lines)
    return vim.tbl_map(function(line)
      return line.text
    end, lines)
  end

  it("keeps every line within the width", function()
    local sample = "日本語のみの長い文章です。" .. string.rep("あいうえお", 10)
    for width = 4, 40 do
      for _, line in ipairs(text.wrap(sample, width)) do
        assert.is_true(text.width(line.text) <= width)
      end
    end
  end)

  it("breaks ASCII at spaces rather than mid word", function()
    local lines = texts(text.wrap("alpha bravo charlie delta", 12))
    assert.are.same({ "alpha bravo", "charlie" , "delta" }, lines)
  end)

  it("reports a range that reproduces the line", function()
    local sample = "`min_col_width` を下回らない幅で折り返し、`debounce` の間隔で描き直す"
    for width = 6, 40 do
      for _, line in ipairs(text.wrap(sample, width)) do
        assert.are.equal(line.text, vim.fn.strcharpart(sample, line.from - 1, line.to - line.from + 1))
      end
    end
  end)

  it("never splits a grapheme cluster", function()
    local warn = "⚠\239\184\143" -- U+26A0 with a variation selector
    local sample = "abc " .. warn .. " def " .. warn .. " ghi"
    for width = 2, 20 do
      for _, line in ipairs(text.wrap(sample, width)) do
        assert.is_nil(line.text:match("^\239\184\143"))
      end
    end
  end)

  it("splits on newlines coming from <br>", function()
    assert.are.same({ "one", "two" }, texts(text.wrap("one\ntwo", 20)))
  end)

  it("measures full-width characters as two cells", function()
    assert.are.equal(2, text.width("あ"))
    assert.are.equal(1, text.width("a"))
  end)
end)

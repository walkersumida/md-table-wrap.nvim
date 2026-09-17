local M = {}

function M.width(s)
  return vim.fn.strdisplaywidth(s)
end

-- Characters that form one grapheme cluster together with the preceding character.
-- Breaking a line in front of one leaves a combining character whose width the
-- terminal resolves differently, shifting the row by a cell.
local function attaches_to_previous(ch)
  local cp = vim.fn.char2nr(ch)
  return cp == 0x200D -- zero width joiner
    or cp == 0xFE0E
    or cp == 0xFE0F -- variation selectors
    or (cp >= 0x1F3FB and cp <= 0x1F3FF) -- skin tone modifiers
    or M.width(ch) == 0
end

-- Measures the prefix rather than adding up per-character widths, which do not add up
-- to the width of a grapheme cluster. The scan stops at the first prefix wider than the
-- column, so it walks a long cell only as far as the column reaches.
local function longest_prefix(text, chars, width)
  local taken = 0
  for i = 1, chars do
    if M.width(vim.fn.strcharpart(text, 0, i)) > width then
      break
    end
    taken = i
  end
  return taken
end

-- Japanese breaks anywhere; a run of ASCII backs up to the last space so words stay
-- whole. Each line carries the character range it covers so highlights can be mapped
-- back onto it.
---@return { text: string, from: integer, to: integer }[]
function M.wrap(text, width)
  if width < 1 then
    width = 1
  end
  local result = {}
  local paragraphs = vim.split(text, "\n", { plain = true })
  local offset = 0
  for index, paragraph in ipairs(paragraphs) do
    local consumed = 0
    local rest = paragraph
    if paragraph == "" then
      table.insert(result, { text = "", from = offset + 1, to = offset })
    end
    while rest ~= "" do
      local chars = vim.fn.strchars(rest)
      local taken = chars
      if M.width(rest) > width then
        taken = longest_prefix(rest, chars, width)

        while taken > 0 and taken < chars and attaches_to_previous(vim.fn.strcharpart(rest, taken, 1)) do
          taken = taken - 1
        end
        if taken == 0 then
          taken = 1
          while taken < chars and attaches_to_previous(vim.fn.strcharpart(rest, taken, 1)) do
            taken = taken + 1
          end
        end

        local head = vim.fn.strcharpart(rest, 0, taken)
        local next_char = vim.fn.strcharpart(rest, taken, 1)
        if next_char:match("[%w%p]") and head:match("[%w%p]$") then
          local space = head:find("%s[^%s]*$")
          if space then
            taken = vim.fn.strchars(head:sub(1, space))
          end
        end
      end

      local line = (vim.fn.strcharpart(rest, 0, taken):gsub("%s+$", ""))
      table.insert(result, {
        text = line,
        from = offset + consumed + 1,
        to = offset + consumed + vim.fn.strchars(line),
      })

      consumed = consumed + taken
      local remainder = vim.fn.strcharpart(rest, taken)
      local trimmed = (remainder:gsub("^%s+", ""))
      consumed = consumed + vim.fn.strchars(remainder) - vim.fn.strchars(trimmed)
      rest = trimmed
    end
    offset = offset + vim.fn.strchars(paragraph)
    if index < #paragraphs then
      offset = offset + 1
    end
  end
  return result
end

return M

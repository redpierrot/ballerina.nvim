local M = {}

-- Minimal brace/paren-aware indentexpr for Ballerina. There's no
-- treesitter grammar for Ballerina, so plain 'autoindent' just copies the
-- previous line verbatim.
--
-- 'cindent'/'smartindent' were tried and rejected: cindent misreads
-- module-qualified calls like `io:println(...)` as C jump labels
-- (`identifier:`) and snaps them back to column 0.
--
-- Tracks "..." strings (backslash escapes) and `...` templates (no escape
-- processing — backslash is literal in templates). A bare ' is Ballerina's
-- quoted-identifier prefix (`int 'from = 5;`) with no closing quote, not a
-- string delimiter, so it is ignored entirely.
local function strip_line_comment(line)
  local in_str = nil
  local i = 1
  local n = #line
  while i <= n do
    local c = line:sub(i, i)
    if in_str then
      if c == "\\" and in_str == '"' then
        i = i + 1
      elseif c == in_str then
        in_str = nil
      end
    else
      if c == '"' or c == "`" then
        in_str = c
      elseif c == "/" and line:sub(i + 1, i + 1) == "/" then
        return line:sub(1, i - 1)
      end
    end
    i = i + 1
  end
  return line
end

-- Computes the indent for `lnum` in the current buffer.
---@param lnum integer? 1-based line number; defaults to v:lnum (set by 'indentexpr')
---@return integer
M.indentexpr = function(lnum)
  lnum = lnum or vim.v.lnum
  if lnum <= 1 then
    return 0
  end

  local prevlnum = vim.fn.prevnonblank(lnum - 1)
  if prevlnum == 0 then
    return 0
  end

  local sw = vim.fn.shiftwidth()
  local prevline = strip_line_comment(vim.fn.getline(prevlnum))
  local curline = vim.fn.getline(lnum)

  local ind = vim.fn.indent(prevlnum)
  if prevline:match("[{(%[]%s*$") then
    ind = ind + sw
  end
  if curline:match("^%s*[%)%}%]]") then
    ind = ind - sw
  end

  return math.max(ind, 0)
end

return M

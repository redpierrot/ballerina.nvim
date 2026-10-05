-- mini.ai text objects for Ballerina, found without a grammar: comments and
-- string-likes are masked out of the buffer text, braces are paired on what is
-- left, and constructs are located by keyword. Design and limitations:
-- docs/proposals/textobjects.md.

local M = {}

---@class ballerina.TextobjectEntry
---@field start integer Byte offset where the outer (`a`) region starts.
---@field stop integer Byte offset where the outer region ends (inclusive).
---@field bodies { [1]: integer, [2]: integer }[] `{`/`}` offsets of each body.

-- Modifiers that precede a declaration keyword and belong to it.
local QUALIFIERS = {
  public = true,
  private = true,
  isolated = true,
  transactional = true,
  remote = true,
  resource = true,
  client = true,
  service = true,
  readonly = true,
  distinct = true,
}

-- Statements introduced by a keyword and followed by a `{ ... }` body.
local STATEMENTS = {
  ["if"] = true,
  ["while"] = true,
  foreach = true,
  match = true,
  ["do"] = true,
  lock = true,
  transaction = true,
  retry = true,
  fork = true,
  worker = true,
}

-- Declarations that `c` selects.
local CLASSES = {
  class = true,
  service = true,
  enum = true,
  record = true,
  object = true,
}

---Replace comments, string literals, backtick templates and quoted
---identifiers with spaces. Length and newlines are preserved, so offsets into
---the result are offsets into `text`.
---@param text string
---@return string
local function mask(text)
  local n = #text
  local out, last, pos = {}, 1, 1
  while true do
    local i = text:find("[/\"`']", pos)
    if not i then
      break
    end
    local c = text:sub(i, i)
    local j
    if c == "/" then
      if text:sub(i + 1, i + 1) == "/" then
        j = (text:find("\n", i, true) or n + 1) - 1
      end
    elseif c == '"' then
      local k = i + 1
      while k <= n do
        local ch = text:byte(k)
        if ch == 92 then -- backslash: skip the escaped byte
          k = k + 2
        elseif ch == 34 or ch == 10 then
          break
        else
          k = k + 1
        end
      end
      j = text:byte(k) == 34 and k or math.min(k - 1, n)
    elseif c == "`" then
      j = text:find("`", i + 1, true) or n
    else
      local _, e = text:find("^'[%a_][%w_]*", i)
      j = e
    end
    if j then
      out[#out + 1] = text:sub(last, i - 1)
      out[#out + 1] = (text:sub(i, j):gsub("[^\n]", " "))
      last = j + 1
      pos = j + 1
    else
      pos = i + 1
    end
  end
  out[#out + 1] = text:sub(last)
  return table.concat(out)
end

---`open -> close` offsets for every balanced `{`/`}` pair.
---@param m string masked text
---@return table<integer, integer>
local function pair_braces(m)
  local pair, stack = {}, {}
  local pos = 1
  while true do
    local i = m:find("[{}]", pos)
    if not i then
      break
    end
    if m:byte(i) == 123 then
      stack[#stack + 1] = i
    elseif #stack > 0 then
      pair[table.remove(stack)] = i
    end
    pos = i + 1
  end
  return pair
end

---Offset of the last non-whitespace byte before `pos`, or nil.
local function prev_nonspace(m, pos)
  local j = pos - 1
  while j >= 1 and m:sub(j, j):match("%s") do
    j = j - 1
  end
  return j >= 1 and j or nil
end

---The identifier ending at or before `pos` (skipping whitespace), and where
---it starts.
local function prev_word(m, pos)
  local base = math.max(1, pos - 40)
  local s, w = m:sub(base, pos - 1):match("()([%a_][%w_]*)%s*$")
  if s then
    return base + s - 1, w
  end
end

---Does a `{` at `i` (depth 0 in a header) open a mapping constructor or a
---record/object type, rather than the body?
local function opens_expression(m, i)
  local j = prev_nonspace(m, i)
  if not j then
    return false
  end
  if m:sub(j, j):match("[=%(%[,:+%-*/%%&!]") then
    return true
  end
  local _, w = prev_word(m, i)
  return w == "in" or w == "return" or w == "record" or w == "object"
end

---Find the `{` that starts the body of the construct whose header begins at
---`pos`. Returns nil when the construct has none (`;`, `= external`, a
---function type descriptor, ...).
---@param m string masked text
---@param pos integer
---@param pair table<integer, integer>
---@param generic boolean function header: `<>` nest and `=`/`,` end the search
local function find_body(m, pos, pair, generic)
  local pattern = generic and "[%(%)%[%]<>{};=,]" or "[%(%)%[%]{};]"
  local depth = 0
  while true do
    local i = m:find(pattern, pos)
    if not i then
      return nil
    end
    local c = m:sub(i, i)
    if c == "(" or c == "[" or c == "<" then
      depth = depth + 1
      pos = i + 1
    elseif c == ")" or c == "]" or c == ">" then
      depth = depth - 1
      if depth < 0 then
        return nil
      end
      pos = i + 1
    elseif c == "{" then
      if depth == 0 and not opens_expression(m, i) then
        return i
      end
      local close = pair[i]
      if not close then
        return nil
      end
      pos = close + 1
    elseif depth == 0 then -- `;` `=` `,`
      return nil
    else
      pos = i + 1
    end
  end
end

---Pull leading qualifiers into an outer region starting at `start`.
local function extend_qualifiers(m, start)
  while true do
    local s, w = prev_word(m, start)
    if not (w and QUALIFIERS[w]) then
      return start
    end
    start = s
  end
end

---After a body closing at `close`, follow `else`/`else if` (for `if`) or
---`on fail` clauses, returning the extra bodies.
---@return { [1]: integer, [2]: integer }[]
local function chain(m, kw, close, pair)
  local bodies = {}
  while true do
    local nxt = m:match("^%s*()%S", close + 1)
    if not nxt then
      return bodies
    end
    local open
    if kw == "if" and m:find("^else%f[^%w_]", nxt) then
      local after = m:match("^%s*()%S", nxt + 4)
      if not after then
        return bodies
      end
      if m:find("^if%f[^%w_]", after) then
        open = find_body(m, after + 2, pair, false)
      elseif m:sub(after, after) == "{" then
        open = after
      end
    elseif kw ~= "if" and m:find("^on%s+fail%f[^%w_]", nxt) then
      open = find_body(m, nxt + 2, pair, false)
    end
    local nclose = open and pair[open]
    if not nclose then
      return bodies
    end
    bodies[#bodies + 1] = { open, nclose }
    close = nclose
  end
end

---Index entries by body brace and keep the one with the earliest start, so
---`retry transaction {` and `else if` style overlaps yield a single object.
local function dedupe(entries)
  local by_open = {}
  for _, e in ipairs(entries) do
    local key = e.bodies[1][1]
    local seen = by_open[key]
    if not seen or e.start < seen.start then
      by_open[key] = e
    end
  end
  local list = vim.tbl_values(by_open)
  table.sort(list, function(a, b)
    return a.start < b.start
  end)
  return list
end

---Find every function, block statement and class-like declaration in `text`.
---@param text string
---@return { func: ballerina.TextobjectEntry[], block: ballerina.TextobjectEntry[], class: ballerina.TextobjectEntry[] }
function M.scan(text)
  local m = mask(text)
  local pair = pair_braces(m)
  local found = { func = {}, block = {}, class = {} }

  for s, word, e in m:gmatch("()([%a_][%w_]*)()") do
    local jp = prev_nonspace(m, s)
    local after = m:sub(e, e)
    local member = (jp and m:sub(jp, jp) == ".") or after == ":"
    if not member then
      if word == "function" then
        local open = find_body(m, e, pair, true)
        local close = open and pair[open]
        if close then
          found.func[#found.func + 1] =
            { start = extend_qualifiers(m, s), stop = close, bodies = { { open, close } } }
        end
      elseif STATEMENTS[word] then
        local _, prev = prev_word(m, s)
        if not (word == "if" and prev == "else") then
          local open = find_body(m, e, pair, false)
          local close = open and pair[open]
          if close then
            local bodies = { { open, close } }
            local extra = chain(m, word, close, pair)
            vim.list_extend(bodies, extra)
            found.block[#found.block + 1] = {
              start = s,
              stop = bodies[#bodies][2],
              bodies = bodies,
            }
          end
        end
      elseif CLASSES[word] then
        local open
        if word == "record" or word == "object" then
          open = m:match("^%s*(){", e)
        elseif not m:find("^%s*object%f[^%w_]", e) then -- `service object {`
          open = find_body(m, e, pair, false)
        end
        local close = open and pair[open]
        if close then
          local start, stop = s, close
          if word == "record" or word == "object" then
            local ts = m:sub(math.max(1, s - 80), s - 1):match("()type%s+[%a_][%w_]*%s*$")
            if ts then
              start = math.max(1, s - 80) + ts - 1
              local semi = m:match("^[ \t]*;()", close + 1)
              if semi then
                stop = semi - 1
              end
            end
          end
          found.class[#found.class + 1] = {
            start = extend_qualifiers(m, start),
            stop = stop,
            bodies = { { open, close } },
          }
        end
      end
    end
  end

  -- `pattern => { ... }` match clause bodies.
  for open in m:gmatch("=>%s*(){") do
    local close = pair[open]
    if close then
      found.block[#found.block + 1] = { start = open, stop = close, bodies = { { open, close } } }
    end
  end

  found.func = dedupe(found.func)
  found.block = dedupe(found.block)
  found.class = dedupe(found.class)
  return found
end

---Convert a 1-based byte offset to a 1-based { line, col }.
local function to_pos(line_starts, offset)
  local lo, hi = 1, #line_starts
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    if line_starts[mid] <= offset then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return { line = lo, col = offset - line_starts[lo] + 1 }
end

---Byte span of a body's contents with the whitespace hugging the braces
---trimmed (so `cif` leaves `{` and `}` on their own lines), or nil if empty.
local function inner_span(text, open, close)
  local seg = text:sub(open + 1, close - 1)
  local l = seg:match("^%s*()")
  local r = seg:match(".*%S()")
  if r and l < r then
    return open + l, open + r - 1
  end
end

---@type { buf: integer, tick: integer, text: string, line_starts: integer[], found: table }?
local cache

local function snapshot()
  local buf = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if cache and cache.buf == buf and cache.tick == tick then
    return cache
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local line_starts, offset = {}, 1
  for i, line in ipairs(lines) do
    line_starts[i] = offset
    offset = offset + #line + 1
  end
  local text = table.concat(lines, "\n")
  cache = { buf = buf, tick = tick, text = text, line_starts = line_starts, found = M.scan(text) }
  return cache
end

---Build a mini.ai custom textobject spec for one kind of object.
---@param kind "func"|"block"|"class"
---@return fun(ai_type: string): table[]
function M.spec(kind)
  return function(ai_type)
    local snap = snapshot()
    local regions = {}
    for _, entry in ipairs(snap.found[kind]) do
      if ai_type == "a" then
        regions[#regions + 1] = {
          from = to_pos(snap.line_starts, entry.start),
          to = to_pos(snap.line_starts, entry.stop),
        }
      else
        for _, body in ipairs(entry.bodies) do
          local from, to = inner_span(snap.text, body[1], body[2])
          if from then
            regions[#regions + 1] = {
              from = to_pos(snap.line_starts, from),
              to = to_pos(snap.line_starts, to),
            }
          end
        end
      end
    end
    return regions
  end
end

M.func = M.spec("func")
M.block = M.spec("block")
M.class = M.spec("class")

---Register the specs on the buffer-local mini.ai config, leaving any spec the
---user already set buffer-locally alone.
---@param bufnr integer
function M.attach(bufnr)
  local opts = require("ballerina.config").options.textobjects
  if not opts.enabled then
    return
  end
  local cfg = vim.b[bufnr].miniai_config or {}
  local custom = cfg.custom_textobjects or {}
  for kind, key in pairs(opts.keys) do
    if key and custom[key] == nil then
      custom[key] = M[kind]
    end
  end
  cfg.custom_textobjects = custom
  vim.b[bufnr].miniai_config = cfg
end

---Undo `attach` (used when the filetype changes away from ballerina).
---@param bufnr integer
function M.detach(bufnr)
  local cfg = vim.b[bufnr].miniai_config
  if not (cfg and cfg.custom_textobjects) then
    return
  end
  for key, spec in pairs(cfg.custom_textobjects) do
    if spec == M.func or spec == M.block or spec == M.class then
      cfg.custom_textobjects[key] = nil
    end
  end
  vim.b[bufnr].miniai_config = cfg
end

return M

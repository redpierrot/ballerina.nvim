local M = {}

-- Quickfix format for Ballerina compiler diagnostics, e.g.
--   ERROR [main.bal:(4:5,4:18)] undefined symbol 'foo'
--   WARNING [modules/util/helper.bal:(2:1,2:10)] unused variable 'x'
-- %t takes the leading E/W as the entry type; %e/%k capture the range end.
-- compiler/ballerina.vim reads this value, so the two never drift.
M.errorformat = table.concat({
  [[%tRROR [%f:(%l:%c\,%e:%k)] %m]],
  [[%tARNING [%f:(%l:%c\,%e:%k)] %m]],
}, ",")

-- Builds the argv for `bal <subcommand>`. User arguments before a literal
-- `--` are CLI options and go before the target; the `--` and everything
-- after it are program arguments and go after it, matching
-- `bal run [options] [target] [-- program-args]`.
---@param bal string resolved bal binary
---@param subcommand string e.g. "run"
---@param target string? explicit target (standalone script), nil inside a package
---@param fargs string[]? user-supplied arguments
---@return string[]
M.build_cmd = function(bal, subcommand, target, fargs)
  local cmd = { bal, subcommand }
  local post = {}
  local seen_dashes = false
  for _, arg in ipairs(fargs or {}) do
    if seen_dashes or arg == "--" then
      seen_dashes = true
      post[#post + 1] = arg
    else
      cmd[#cmd + 1] = arg
    end
  end
  if target then
    cmd[#cmd + 1] = target
  end
  vim.list_extend(cmd, post)
  return cmd
end

-- Quickfix resolves relative filenames against Neovim's cwd, but the job
-- ran in `cwd` (the package root) — rewrite diagnostic paths to absolute.
local function resolve_path(file, cwd)
  if vim.fn.isabsolutepath(file) == 1 then
    return file
  end
  return cwd .. "/" .. file
end

local function absolutize(line, cwd)
  return (
    line:gsub("^(%u+ %[)(.-)(:%(%d+:%d+)", function(prefix, file, rest)
      return prefix .. resolve_path(file, cwd) .. rest
    end)
  )
end

-- `bal test` assertion failures don't produce a compiler diagnostic (no
-- `ERROR [file:(l:c,l:c)]` line), so M.errorformat can't see them at all --
-- they're a separate report shape: a `[fail] <name>:` marker followed by a
-- Ballerina stack trace with no column info, only `fileName: ... lineNumber:
-- N` frames, e.g.:
--
--   [fail] testAddWrong:
--       error {ballerina/test:0}TestError ("Assertion Failed! ...")
--           callableName: createBallerinaError moduleName: ballerina.test.0
--             fileName: assert.bal lineNumber: 41
--           callableName: testAddWrong
--             moduleName: demo.qfcheck$test.0.tests.main_test
--             fileName: tests/main_test.bal lineNumber: 10
--           ...
--
-- The first frames are always internal `ballerina/test` library plumbing
-- (assert.bal, serialExecuter.bal, ...) and the trace also includes
-- compiler-generated test-harness glue (`*-generated*.bal`); neither is
-- useful as a jump target. We want the first frame that's neither, which is
-- reliably the user's own test function.
local function is_internal_frame(frame)
  return frame.module:match("^ballerina%.") ~= nil
    or frame.file:match("%-generated") ~= nil
    or frame.file:match("_generated") ~= nil
end

local function first_user_frame(frames)
  for _, frame in ipairs(frames) do
    if not is_internal_frame(frame) then
      return frame
    end
  end
  return nil
end

-- Collapses the free-form error message lines (arbitrary internal
-- whitespace/newlines from the terminal output) into one line, and strips
-- the `error {mod:ver}TypeName ("..."）` wrapper Ballerina prints error
-- values with, e.g. `error {ballerina/test:0}TestError ("Assertion Failed!
-- ...")` -> `Assertion Failed! ...`. If the message doesn't match that
-- shape (not every failure is an assertion), it's left as-is.
local function clean_test_message(raw_lines)
  local msg = table.concat(raw_lines, " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  msg = msg:gsub('^error%s*%b{}%a*%s*%("', "")
  msg = msg:gsub('"%)$', "")
  return msg
end

---@param lines string[] raw (unmodified) `bal test` output lines
---@param cwd string package root the job ran in, for resolving relative paths
---@return table[] quickfix items, one per failure resolvable to a user frame
M.parse_test_failures = function(lines, cwd)
  local items = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^%s*%[fail%]%s+(%S-):%s*$")
    if not name then
      i = i + 1
    else
      local msg_lines, frames = {}, {}
      i = i + 1
      while
        i <= #lines
        and not lines[i]:match("^%s*%[%a+%]")
        and not lines[i]:match("^%s*%d+%s+%a+%s*$")
      do
        local module, file, lnum =
          lines[i]:match("moduleName:%s*(%S+)%s+fileName:%s*(%S+)%s+lineNumber:%s*(%d+)")
        if module then
          frames[#frames + 1] = { module = module, file = file, lnum = tonumber(lnum) }
        elseif #frames == 0 then
          msg_lines[#msg_lines + 1] = lines[i]
        end
        i = i + 1
      end
      local frame = first_user_frame(frames)
      if frame then
        items[#items + 1] = {
          filename = resolve_path(frame.file, cwd),
          lnum = frame.lnum,
          col = 1,
          type = "E",
          text = ("test failed: %s — %s"):format(name, clean_test_message(msg_lines)),
        }
      end
    end
  end
  return items
end

---@return boolean whether any quickfix items were populated
local function populate_quickfix(lines, cwd, title)
  local rewritten = {}
  for _, line in ipairs(lines) do
    rewritten[#rewritten + 1] = absolutize(line, cwd)
  end
  local parsed = vim.fn.getqflist({ lines = rewritten, efm = M.errorformat })
  local items = vim.tbl_filter(function(item)
    return item.valid == 1
  end, parsed.items)
  vim.list_extend(items, M.parse_test_failures(lines, cwd))

  vim.fn.setqflist({}, " ", { items = items, title = title })
  if #items > 0 then
    vim.notify(
      ("%d problem(s) in the quickfix list — :copen to view"):format(#items),
      vim.log.levels.INFO,
      { title = "Ballerina" }
    )
  end
  return #items > 0
end

-- Run `bal <subcommand>` for the buffer's enclosing package (or the
-- standalone script) in a terminal split, so output streams live and
-- long-running `bal run` services keep going until the terminal is closed.
-- On exit, compiler diagnostics from the output land in the quickfix list.
---@param subcommand string e.g. "run", "test", "build"
---@param bufnr integer? buffer whose package to target, 0/nil for current
---@param fargs string[]? extra arguments, see build_cmd()
M.run = function(subcommand, bufnr, fargs)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end

  local util = require("ballerina.util")
  local bal = util.bal_cmd()
  if not bal then
    util.warn_missing_bal()
    return
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    vim.notify("Buffer has no file name", vim.log.levels.WARN, { title = "Ballerina" })
    return
  end

  -- Inside a package the subcommand targets the whole package from its
  -- root; a standalone script is passed explicitly.
  local root = vim.fs.root(filepath, "Ballerina.toml")
  local cwd = root or vim.fs.dirname(filepath)
  local cmd = M.build_cmd(bal, subcommand, root == nil and filepath or nil, fargs)

  vim.cmd.split()
  vim.cmd.enew()
  local term_buf = vim.api.nvim_get_current_buf()
  local term_win = vim.api.nvim_get_current_win()
  vim.fn.jobstart(cmd, {
    cwd = cwd,
    term = true,
    on_exit = function()
      if not vim.api.nvim_buf_is_valid(term_buf) then
        return
      end
      local lines = vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)
      local has_items = populate_quickfix(lines, cwd, table.concat(cmd, " "))
      if not has_items then
        return
      end
      -- Don't pop the quickfix window open over the terminal the user is
      -- still reading -- wait for them to close it first. If it's already
      -- closed by the time the job exits (they didn't wait around), open
      -- immediately instead of waiting for a close event that already happened.
      if not vim.api.nvim_win_is_valid(term_win) then
        vim.cmd.copen()
        return
      end
      vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(term_win),
        once = true,
        callback = function()
          vim.schedule(function()
            vim.cmd.copen()
          end)
        end,
      })
    end,
  })
  -- Unlike `:terminal`, a buffer put into terminal mode via `jobstart`
  -- doesn't auto-enter terminal-job mode: without this, keys typed right
  -- after opening (e.g. <C-c> to stop a long-running `bal run` service)
  -- land in terminal-normal mode instead of reaching the job.
  vim.cmd.startinsert()
end

return M

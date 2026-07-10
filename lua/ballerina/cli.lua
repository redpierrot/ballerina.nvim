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
local function absolutize(line, cwd)
  return (line:gsub("^(%u+ %[)(.-)(:%(%d+:%d+)", function(prefix, file, rest)
    if vim.fn.isabsolutepath(file) == 0 then
      file = cwd .. "/" .. file
    end
    return prefix .. file .. rest
  end))
end

local function populate_quickfix(lines, cwd, title)
  local rewritten = {}
  for _, line in ipairs(lines) do
    rewritten[#rewritten + 1] = absolutize(line, cwd)
  end
  local parsed = vim.fn.getqflist({ lines = rewritten, efm = M.errorformat })
  local items = vim.tbl_filter(function(item)
    return item.valid == 1
  end, parsed.items)

  vim.fn.setqflist({}, " ", { items = items, title = title })
  if #items > 0 then
    vim.notify(
      ("%d problem(s) in the quickfix list — :copen to view"):format(#items),
      vim.log.levels.INFO,
      { title = "Ballerina" }
    )
  end
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
  vim.fn.jobstart(cmd, {
    cwd = cwd,
    term = true,
    on_exit = function()
      if not vim.api.nvim_buf_is_valid(term_buf) then
        return
      end
      local lines = vim.api.nvim_buf_get_lines(term_buf, 0, -1, false)
      populate_quickfix(lines, cwd, table.concat(cmd, " "))
    end,
  })
end

return M

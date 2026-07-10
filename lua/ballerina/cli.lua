local M = {}

-- Run `bal <subcommand>` for the buffer's enclosing package (or the
-- standalone script) in a terminal split, so output streams live and
-- long-running `bal run` services keep going until the terminal is closed.
---@param subcommand string e.g. "run", "test", "build"
---@param bufnr integer? buffer whose package to target, 0/nil for current
M.run = function(subcommand, bufnr)
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
  local cmd = root and { bal, subcommand } or { bal, subcommand, filepath }
  local cwd = root or vim.fs.dirname(filepath)

  vim.cmd.split()
  vim.cmd.enew()
  vim.fn.jobstart(cmd, { cwd = cwd, term = true })
end

return M

if vim.b.did_ballerina_ftplugin then
  return
end
vim.b.did_ballerina_ftplugin = true

local bufnr = vim.api.nvim_get_current_buf()
local config = require("ballerina.config").options

-- `bal format` uses 4-space indentation.
vim.opt_local.shiftwidth = 4
vim.opt_local.tabstop = 4
vim.opt_local.softtabstop = 4
vim.opt_local.expandtab = true
vim.opt_local.commentstring = "// %s"

if config.indent then
  vim.opt_local.autoindent = true
  vim.opt_local.smartindent = false
  vim.opt_local.cindent = false
  vim.opt_local.indentexpr = "v:lua.require'ballerina.indent'.indentexpr()"
  vim.opt_local.indentkeys = "0{,0},0),0],!^F,o,O,e"
end

-- Registered unconditionally and gated inside the callback, so toggling
-- `format_on_save` (or setup() running after this buffer opened) takes
-- effect without reopening the buffer.
local group = vim.api.nvim_create_augroup("ballerina_ftplugin_" .. bufnr, { clear = true })
vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  buffer = bufnr,
  desc = "Run `bal format` on the enclosing package after save",
  callback = function(args)
    local opts = require("ballerina.config").options
    if not opts.format_on_save or vim.b[args.buf].ballerina_disable_format then
      return
    end
    require("ballerina.format").format(args.buf)
  end,
})

vim.api.nvim_buf_create_user_command(bufnr, "BallerinaFormat", function()
  require("ballerina.format").format(bufnr)
end, { desc = "Format the file (or its enclosing package) with `bal format`" })

vim.api.nvim_buf_create_user_command(bufnr, "BallerinaFormatToggle", function()
  local disabled = not vim.b[bufnr].ballerina_disable_format
  vim.b[bufnr].ballerina_disable_format = disabled
  vim.notify(
    "format-on-save " .. (disabled and "disabled" or "enabled") .. " for this buffer",
    vim.log.levels.INFO,
    { title = "Ballerina" }
  )
end, { desc = "Toggle format-on-save for this buffer" })

for command, subcommand in pairs({
  BallerinaRun = "run",
  BallerinaTest = "test",
  BallerinaBuild = "build",
}) do
  vim.api.nvim_buf_create_user_command(bufnr, command, function(opts)
    require("ballerina.cli").run(subcommand, bufnr, opts.fargs)
  end, {
    nargs = "*",
    complete = "file",
    desc = "Run `bal " .. subcommand .. "` on the file/package in a terminal split",
  })
end

if config.dap.enabled then
  require("ballerina.dap").setup()
end

vim.b.undo_ftplugin = table.concat({
  "setlocal shiftwidth< tabstop< softtabstop< expandtab< commentstring<",
  "setlocal autoindent< smartindent< cindent< indentexpr< indentkeys<",
  ("silent! autocmd! ballerina_ftplugin_%d"):format(bufnr),
  "silent! delcommand -buffer BallerinaFormat",
  "silent! delcommand -buffer BallerinaFormatToggle",
  "silent! delcommand -buffer BallerinaRun",
  "silent! delcommand -buffer BallerinaTest",
  "silent! delcommand -buffer BallerinaBuild",
  "unlet! b:did_ballerina_ftplugin",
}, " | ")

---@class ballerina.LspConfig
---@field enabled boolean Start the Ballerina language server for .bal buffers.
---@field root_markers string[] Files/directories that mark the workspace root.
---@field config table? Extra fields merged into the LSP client config, e.g.
---`capabilities`, `settings`, `init_options` (see :h vim.lsp.Config).

---@class ballerina.Config
---@field bal_cmd string? Path to the `bal` binary. nil = auto-detect (PATH,
---then the known install locations of the official distributions).
---@field format_on_save boolean Run `bal format` after saving a .bal file.
---@field indent boolean Use the bundled brace/paren-aware indentexpr.
---@field lsp ballerina.LspConfig

local M = {}

---@type ballerina.Config
M.defaults = {
  bal_cmd = nil,
  format_on_save = true,
  indent = true,
  lsp = {
    enabled = true,
    root_markers = { "Ballerina.toml" },
    config = nil,
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts ballerina.Config|table|nil
M.setup = function(opts)
  opts = opts or {}
  vim.validate("bal_cmd", opts.bal_cmd, "string", true)
  vim.validate("format_on_save", opts.format_on_save, "boolean", true)
  vim.validate("indent", opts.indent, "boolean", true)
  vim.validate("lsp", opts.lsp, "table", true)

  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
end

return M

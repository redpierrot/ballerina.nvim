local M = {}

---@param opts ballerina.Config|table|nil see `:h ballerina.nvim-config` for available options
M.setup = function(opts)
  require("ballerina.config").setup(opts)
  require("ballerina.lsp").setup()
end

return M

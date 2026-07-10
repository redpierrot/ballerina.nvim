local M = {}

-- The server definition itself lives in lsp/ballerina.lua (:h lsp-config)
-- and is read lazily by Neovim. This only layers the user's options on top
-- and flips the enable switch. Idempotent, so it is safe that ftdetect/
-- enables the client with defaults at startup and setup() runs this again
-- once the user's options are merged in.
M.setup = function()
  local config = require("ballerina.config").options

  vim.lsp.config(
    "ballerina",
    vim.tbl_deep_extend(
      "force",
      { root_markers = config.lsp.root_markers },
      config.lsp.config or {}
    )
  )
  vim.lsp.enable("ballerina", config.lsp.enabled)
end

return M

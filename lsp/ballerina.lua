-- Native vim.lsp.config definition (:h lsp-config), read lazily when the
-- first ballerina buffer opens. nvim-lspconfig ships an equivalent file;
-- Neovim merges same-named definitions, and anything set through
-- vim.lsp.config("ballerina", ...) — which is what setup() uses for user
-- options — wins over both.
return {
  -- A function instead of a static table so the binary is resolved when the
  -- server actually starts (never at Neovim startup), and so the
  -- config-override + install-location fallback logic in util.bal_cmd()
  -- applies.
  cmd = function(dispatchers)
    local util = require("ballerina.util")
    local bal = util.bal_cmd()
    if not bal then
      util.warn_missing_bal()
      error("ballerina.nvim: `bal` executable not found", 0)
    end
    return vim.lsp.rpc.start({ bal, "start-language-server" }, dispatchers)
  end,
  filetypes = { "ballerina" },
  root_markers = { "Ballerina.toml" },
}

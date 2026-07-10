local M = {}

-- :checkhealth ballerina
M.check = function()
  local health = vim.health
  health.start("ballerina.nvim")

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim >= 0.11")
  else
    health.error("Neovim >= 0.11 is required (vim.lsp.config, vim.system, jobstart term)")
  end

  local config = require("ballerina.config").options
  local bal = require("ballerina.util").bal_cmd()
  if not bal then
    health.error("`bal` executable not found", {
      "Install Ballerina: https://ballerina.io/downloads/",
      "Or set `bal_cmd` in require('ballerina').setup()",
    })
  else
    local ok, result = pcall(function()
      return vim.system({ bal, "version" }, { text = true }):wait(15000)
    end)
    if ok and result.code == 0 then
      local version = vim.trim(vim.split(result.stdout or "", "\n")[1] or "")
      health.ok(("`bal` found at %s (%s)"):format(bal, version))
    else
      health.warn(("`bal` found at %s, but `bal version` failed"):format(bal))
    end
  end

  if config.lsp.enabled then
    local clients = vim.lsp.get_clients({ name = "ballerina" })
    if #clients > 0 then
      health.ok(("LSP enabled, %d client(s) running"):format(#clients))
    else
      health.ok("LSP enabled (a client starts when a ballerina buffer opens)")
    end
  else
    health.info("LSP disabled via `lsp.enabled = false`")
  end
end

return M

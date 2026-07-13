local M = {}

-- The server definition itself lives in lsp/ballerina.lua (:h lsp-config)
-- and is read lazily by Neovim. This only layers the user's options on top
-- and flips the enable switch. Idempotent, so it is safe that ftdetect/
-- enables the client with defaults at startup and setup() runs this again
-- once the user's options are merged in.
M.setup = function()
  local config = require("ballerina.config").options

  -- dynamicRegistration is set explicitly, every call, never omitted: calls
  -- to vim.lsp.config() merge into whatever was set by a previous call
  -- rather than replacing it, so leaving this out on the file_watch = true
  -- path would not undo an earlier setup() run with file_watch = false.
  -- See ballerina.LspConfig.file_watch for why the default is off.
  local overrides = {
    root_markers = config.lsp.root_markers,
    capabilities = {
      workspace = {
        didChangeWatchedFiles = { dynamicRegistration = config.lsp.file_watch },
      },
    },
  }

  -- Only wired in on the file_watch = true path: a later setup() run with
  -- file_watch = false won't strip the handler back out (merge, not
  -- replace — see the dynamicRegistration comment above), but that's
  -- harmless, since it only ever acts on workspace/didChangeWatchedFiles
  -- registrations, and dynamicRegistration = false means the server never
  -- sends one.
  if config.lsp.file_watch then
    require("ballerina.lsp_watch").apply(overrides)
  end

  vim.lsp.config("ballerina", vim.tbl_deep_extend("force", overrides, config.lsp.config or {}))
  vim.lsp.enable("ballerina", config.lsp.enabled)
end

return M

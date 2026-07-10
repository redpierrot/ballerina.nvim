vim.filetype.add({
  extension = {
    bal = "ballerina",
  },
})

-- Enable the LSP client here rather than in plugin/ so it also works when
-- the plugin is lazy-loaded on `ft = "ballerina"`: lazy.nvim sources
-- ftdetect/ eagerly at startup, before the first FileType event fires.
-- This is registration only — the server definition in lsp/ballerina.lua is
-- read lazily when the first ballerina buffer opens, so no plugin module is
-- required and nothing else runs at startup. setup() re-runs enable() with
-- the user's `lsp.enabled` once options are merged in.
vim.lsp.enable("ballerina")

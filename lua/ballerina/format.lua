local M = {}

local function reload_from_disk(bufnr, filepath)
  local ok, new_lines = pcall(vim.fn.readfile, filepath)
  if not ok then
    return
  end

  -- Skip no-op reloads so undo history and extmarks aren't churned for
  -- files that were already formatted.
  if vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), new_lines) then
    return
  end

  local views = {}
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    views[winid] = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
  vim.bo[bufnr].modified = false

  for winid, view in pairs(views) do
    vim.api.nvim_win_call(winid, function()
      vim.fn.winrestview(view)
    end)
  end
end

-- `bal format` rewrites the whole package, so every other loaded, unmodified
-- .bal buffer under `root` must be reloaded too — a stale buffer would show
-- W12 "file changed on disk" prompts, or silently write unformatted content
-- back over the formatted file. Modified buffers are left alone (never
-- discard unsaved edits).
local function reload_package_buffers(root, skip_bufnr)
  local prefix = vim.fs.normalize(root) .. "/"
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if bufnr ~= skip_bufnr and vim.api.nvim_buf_is_loaded(bufnr) and not vim.bo[bufnr].modified then
      local name = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
      if name:sub(-4) == ".bal" and vim.startswith(name, prefix) then
        reload_from_disk(bufnr, name)
      end
    end
  end
end

-- `bal format` writes formatted output to disk in place (no stdin mode),
-- and it refuses to format a single file that belongs to a package:
--   error: The source file 'main.bal' belongs to a Ballerina package.
-- That rules out the usual "formatter reads stdin, writes stdout" model,
-- since almost every real Ballerina file lives in a package (has a
-- Ballerina.toml ancestor). Instead, format the whole enclosing package
-- (idempotent and cheap for files that are already formatted) and reload
-- the affected buffers from disk afterwards.
--
-- This is the unconditional "format now" primitive; the format_on_save /
-- b:ballerina_disable_format gates live in the ftplugin autocmd so
-- :BallerinaFormat can reuse it.
---@param bufnr integer? buffer to format, 0/nil for the current buffer
M.format = function(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    return
  end

  -- `bal format` reads from disk, so formatting a buffer with unsaved
  -- changes would reload stale content over them.
  if vim.bo[bufnr].modified then
    vim.notify(
      "Buffer has unsaved changes; save before formatting",
      vim.log.levels.WARN,
      { title = "Ballerina" }
    )
    return
  end

  local util = require("ballerina.util")
  local bal_cmd = util.bal_cmd()
  if not bal_cmd then
    util.warn_missing_bal()
    return
  end

  local root = vim.fs.root(filepath, "Ballerina.toml")
  local cmd = root and { bal_cmd, "format" } or { bal_cmd, "format", filepath }
  local cwd = root or vim.fs.dirname(filepath)
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)

  local ok, err = pcall(vim.system, cmd, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local msg = result.stderr
        if not msg or msg == "" then
          msg = result.stdout or ""
        end
        vim.notify("bal format failed:\n" .. msg, vim.log.levels.WARN, { title = "Ballerina" })
        return
      end

      if root then
        reload_package_buffers(root, bufnr)
      end

      -- Skip the reload if the buffer changed again while `bal format` was
      -- still running, so we don't clobber newer, unsaved keystrokes.
      if
        vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_get_changedtick(bufnr) == changedtick
      then
        reload_from_disk(bufnr, filepath)
      end
    end)
  end)
  if not ok then
    vim.notify(
      "bal format could not run: " .. tostring(err),
      vim.log.levels.WARN,
      { title = "Ballerina" }
    )
  end
end

return M

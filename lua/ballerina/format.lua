local M = {}

-- [bufnr] = true while a `bal format` run this plugin started is still
-- in flight for that buffer. See M.guard_write below.
local formatting = {}

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

  -- `bal format` rewrote the file on disk, so Neovim's recorded read/write
  -- timestamp for this buffer is now stale even though the content above
  -- was just resynced to match. Left alone, the *next* :w on this buffer
  -- trips Neovim's own stale-timestamp check and throws up "WARNING: The
  -- file has been changed since reading it!!!" for a change the plugin
  -- itself made. A forced write is a content no-op here (buffer already
  -- matches disk) but refreshes that bookkeeping; noautocmd keeps it from
  -- round-tripping through BufWrite autocmds (e.g. another format-on-save).
  pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("noautocmd write!")
  end)
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

  formatting[bufnr] = true
  local ok, err = pcall(vim.system, cmd, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      formatting[bufnr] = nil

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
    formatting[bufnr] = nil
    vim.notify(
      "bal format could not run: " .. tostring(err),
      vim.log.levels.WARN,
      { title = "Ballerina" }
    )
  end
end

-- `bal format` (spawned by M.format above) can take a second or more —
-- Ballerina's CLI has real JVM startup latency — and it rewrites the file
-- on disk well before its completion callback runs and gets a chance to
-- refresh Neovim's timestamp bookkeeping (see reload_from_disk). If the
-- user edits and saves again inside that window, *that* save's own :w
-- runs Neovim's stale-timestamp check before our callback ever fires,
-- throwing the same false "file has been changed since reading it"
-- warning for a change this plugin caused.
--
-- Called from a BufWritePre autocmd (see ftplugin/ballerina.lua) for
-- every save, so it can pre-empt that check: if a format we started is
-- still in flight for this buffer, force-write the about-to-be-saved
-- (dirty) content immediately. That refreshes the bookkeeping right
-- before Neovim's own write runs its check, so it always sees a fresh
-- timestamp; the buffer content is the user's own newer keystrokes, so
-- it's correct for it to win over whatever `bal format` wrote.
M.guard_write = function(bufnr)
  if not formatting[bufnr] then
    return
  end
  pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("noautocmd write!")
  end)
end

return M

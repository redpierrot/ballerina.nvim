local M = {}

local resolved_cmd

-- Known install locations used by the official distributions, tried when
-- `bal` is not on PATH (common when GUI Neovim is launched outside a login
-- shell). The installers also export $BALLERINA_HOME (the install root,
-- with bin/bal inside), which is checked before these guesses.
local fallback_paths = {
  "/usr/lib/ballerina/bin/bal", -- Linux (deb/rpm installer)
  "/Library/Ballerina/bin/bal", -- macOS installer
  "C:\\Program Files\\Ballerina\\bin\\bal.bat", -- Windows installer
}

local function candidate_paths()
  local candidates = {}
  local home = vim.env.BALLERINA_HOME
  if home and home ~= "" then
    candidates[#candidates + 1] = home .. "/bin/bal"
    candidates[#candidates + 1] = home .. "\\bin\\bal.bat"
  end
  vim.list_extend(candidates, fallback_paths)
  return candidates
end

-- Resolve the `bal` binary: config override, then PATH lookup, then
-- $BALLERINA_HOME, then the known install locations. Returns nil when
-- nothing is found; "not found" is never cached, so an install done
-- mid-session is picked up.
---@return string|nil
M.bal_cmd = function()
  local config = require("ballerina.config").options
  if config.bal_cmd then
    return config.bal_cmd
  end

  if resolved_cmd then
    return resolved_cmd
  end

  local found = vim.fn.exepath("bal")
  if found ~= "" then
    resolved_cmd = found
    return resolved_cmd
  end

  for _, path in ipairs(candidate_paths()) do
    if vim.fn.executable(path) == 1 then
      resolved_cmd = path
      return resolved_cmd
    end
  end

  return nil
end

-- One friendly warning per session, even though format-on-save would
-- otherwise re-trigger it on every write.
M.warn_missing_bal = function()
  vim.notify_once(
    "ballerina.nvim: `bal` executable not found. Install Ballerina"
      .. " (https://ballerina.io/downloads/) or set `bal_cmd` in setup()."
      .. " See :checkhealth ballerina",
    vim.log.levels.WARN,
    { title = "Ballerina" }
  )
end

return M

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

-- Given a distribution root (the BALLERINA_HOME layout), the `bal` launcher
-- inside it: `bin/bal` on Unix, `bin\bal.bat` on Windows. Returns the first
-- that is executable, or nil.
local function bal_in_home(home)
  if not home or home == "" then
    return nil
  end
  for _, path in ipairs({ home .. "/bin/bal", home .. "\\bin\\bal.bat" }) do
    if vim.fn.executable(path) == 1 then
      return path
    end
  end
  return nil
end

-- Resolve the `bal` binary. Explicit config wins over auto-detection:
--   1. bal_cmd  — an exact binary path
--   2. bal_home — a distribution root, resolved to its bin/bal launcher
-- Then auto-detect: PATH, then $BALLERINA_HOME, then the known install
-- locations. Returns nil when nothing is found; "not found" is never cached,
-- so an install done mid-session is picked up.
---@return string|nil
M.bal_cmd = function()
  local config = require("ballerina.config").options
  if config.bal_cmd then
    return config.bal_cmd
  end

  -- Strict when set: resolve the launcher inside the pinned distribution and
  -- return nil if it has none, rather than silently falling back to a system
  -- install — the whole point of bal_home is to pin one specific build (for
  -- language developers trying out local distributions). Not cached, so it
  -- tracks config changes and a build that appears mid-session.
  if config.bal_home then
    return bal_in_home(config.bal_home)
  end

  if resolved_cmd then
    return resolved_cmd
  end

  local found = vim.fn.exepath("bal")
  if found ~= "" then
    resolved_cmd = found
    return resolved_cmd
  end

  local env_home = bal_in_home(vim.env.BALLERINA_HOME)
  if env_home then
    resolved_cmd = env_home
    return resolved_cmd
  end

  for _, path in ipairs(fallback_paths) do
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

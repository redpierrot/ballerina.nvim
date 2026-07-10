local M = {}

local registered = false

local function free_port()
  local tcp = assert(vim.uv.new_tcp())
  tcp:bind("127.0.0.1", 0)
  local port = tcp:getsockname().port
  tcp:close()
  return port
end

-- The adapter requires "ballerina.home" (the distribution directory) to
-- build its `bal run/test --debug` command. `bal home` prints it; cache the
-- answer since it can't change within a session.
local bal_home
local function ballerina_home(bal)
  if bal_home == nil then
    local ok, result = pcall(function()
      return vim.system({ bal, "home" }, { text = true }):wait(15000)
    end)
    bal_home = (ok and result.code == 0) and vim.trim(result.stdout or "") or false
  end
  return bal_home or nil
end

-- The debuggee source: the enclosing package if there is one, else the
-- standalone script.
local function script_path()
  local file = vim.api.nvim_buf_get_name(0)
  return vim.fs.root(file, "Ballerina.toml") or file
end

-- Registers the nvim-dap adapter and configurations for Ballerina. A no-op
-- when nvim-dap isn't installed; called from the ftplugin so it retries on
-- the next ballerina buffer if nvim-dap appears later.
---@return boolean registered
M.setup = function()
  if registered then
    return true
  end
  local ok, dap = pcall(require, "dap")
  if not ok then
    return false
  end
  registered = true

  -- `bal start-debugger-adapter <port>` starts a DAP server — the same
  -- adapter the VS Code extension uses. A function so the binary is
  -- resolved per session (missing bal warns instead of erroring).
  dap.adapters.ballerina = function(callback, _config)
    local util = require("ballerina.util")
    local bal = util.bal_cmd()
    if not bal then
      util.warn_missing_bal()
      return
    end
    local port = free_port()
    callback({
      type = "server",
      host = "127.0.0.1",
      port = port,
      executable = { command = bal, args = { "start-debugger-adapter", tostring(port) } },
      -- The adapter is a JVM process; the default 14 retries (~3.5s) is not
      -- always enough for it to start listening.
      options = { max_retries = 120 },
    })
  end

  -- Request attribute names come from the adapter sources in ballerina-lang
  -- (misc/debug-adapter, ClientConfigHolder/ClientLaunchConfigHolder):
  -- script, ballerina.home, ballerina.command, scriptArguments, debugTests,
  -- debuggeeHost, debuggeePort. "ballerina.home" is required for launch;
  -- "ballerina.command" overrides the executable derived from it, keeping
  -- the plugin's bal_cmd resolution authoritative.
  local function launch(extra)
    return vim.tbl_extend("force", {
      type = "ballerina",
      request = "launch",
      script = script_path,
      ["ballerina.home"] = function()
        local bal = require("ballerina.util").bal_cmd()
        return bal and ballerina_home(bal) or nil
      end,
      ["ballerina.command"] = function()
        return require("ballerina.util").bal_cmd()
      end,
    }, extra)
  end

  dap.configurations.ballerina = dap.configurations.ballerina or {}
  vim.list_extend(dap.configurations.ballerina, {
    launch({ name = "Debug Ballerina program" }),
    launch({
      name = "Debug Ballerina program (prompt for arguments)",
      scriptArguments = function()
        return vim.split(vim.fn.input("Program arguments: "), " +", { trimempty = true })
      end,
    }),
    launch({ name = "Debug Ballerina tests", debugTests = true }),
    {
      type = "ballerina",
      request = "attach",
      name = "Attach to running program (started with `bal run --debug <port>`)",
      script = script_path,
      debuggeeHost = "127.0.0.1",
      debuggeePort = function()
        return vim.fn.input("Debuggee port: ", "5005")
      end,
    },
  })
  return true
end

return M

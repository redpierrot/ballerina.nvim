-- Scopes LSP file watching to Ballerina's package structure so no watch's
-- base_dir is an ancestor of a build-cache directory (target/, .gradle/,
-- ...). See docs/proposals/scoped-lsp-file-watch.md for the full design and
-- why this is necessary: Neovim's recursive fs_event watcher crashes
-- outright (ENAMETOOLONG) on macOS if such a directory ever contains a
-- pathologically long or invalid path, and that crash happens before any
-- include/exclude glob filtering runs — so the only fix is to never let
-- such a directory come under a recursive watch in the first place.
local bit = require("bit")
local protocol = require("vim.lsp.protocol")
local watchfiles = require("vim.lsp._watchfiles")
local watch = vim._watch

local M = {}

-- Exact glob patterns captured from Ballerina LS 2201.13.4's
-- workspace/didChangeWatchedFiles registration. Each entry says how that
-- *specific, known* pattern is re-scoped:
--   root_direct    - matched against direct children of the package root
--                    only, via our own non-recursive watcher (component A).
--   root_dir_event - direct child of root, but the event drives dynamically
--                    starting/stopping a scoped recursive watch rather than
--                    (or in addition to) notifying the server.
--   modules        - folded into the single recursive watch scoped to
--                    <root>/modules (relative pattern, component B).
--   generated       - folded into the recursive watch scoped to
--                    <root>/generated, the main module's generated sources
--                    (component B). Submodule-level generated/ deletion is
--                    covered by the `modules` entry above instead.
-- A pattern not in this table is an unrecognized deviation from the
-- captured contract and is handled by the loud fallback in classify().
M.KNOWN_PATTERNS = {
  ["/**/*.bal"] = {
    root_direct = "*.bal",
    modules = "**/*.bal",
    generated = "**/*.bal",
  },
  ["/**/modules/*"] = {
    modules = "*",
  },
  ["/**/modules"] = {
    root_dir_event = "modules",
  },
  ["/**/generated"] = {
    root_dir_event = "generated",
    modules = "**/generated",
  },
  ["/**/Ballerina.toml"] = {
    root_direct = "Ballerina.toml",
  },
  ["/**/Cloud.toml"] = {
    root_direct = "Cloud.toml",
  },
  ["/**/Dependencies.toml"] = {
    root_direct = "Dependencies.toml",
  },
}

--- Component D. Pure function: groups a server's watcher registrations by
--- how they need to be re-scoped. Independent of any live client, so it's
--- unit-testable against the exact 7-pattern payload captured from the
--- real server (see tests/run.lua).
---@param watchers lsp.FileSystemWatcher[]
---@return { root_direct: table[], root_dir_events: table[], modules: table[],
---generated: table[], unknown: lsp.FileSystemWatcher[] }
function M.classify(watchers)
  local result = {
    root_direct = {},
    root_dir_events = {},
    modules = {},
    generated = {},
    unknown = {},
  }

  for _, w in ipairs(watchers) do
    local pattern = type(w.globPattern) == "string" and w.globPattern or nil
    local route = pattern and M.KNOWN_PATTERNS[pattern]
    if not route then
      table.insert(result.unknown, w)
    else
      local kind = w.kind
        or (protocol.WatchKind.Create + protocol.WatchKind.Change + protocol.WatchKind.Delete)
      if route.root_direct then
        table.insert(result.root_direct, { match = route.root_direct, kind = kind })
      end
      if route.root_dir_event then
        table.insert(result.root_dir_events, { name = route.root_dir_event, kind = kind })
      end
      if route.modules then
        table.insert(result.modules, { pattern = route.modules, kind = kind })
      end
      if route.generated then
        table.insert(result.generated, { pattern = route.generated, kind = kind })
      end
    end
  end

  return result
end

--- @type table<integer, { client: vim.lsp.Client, root: string, routed: table, group_ids: table<string, string> }>
local active = {}

local to_lsp_change_type = {
  [watch.FileChangeType.Created] = protocol.FileChangeType.Created,
  [watch.FileChangeType.Changed] = protocol.FileChangeType.Changed,
  [watch.FileChangeType.Deleted] = protocol.FileChangeType.Deleted,
}

local function kind_matches(kind, lsp_change_type)
  local kind_mask = bit.lshift(1, lsp_change_type - 1)
  return bit.band(kind, kind_mask) == kind_mask
end

-- `rule.match` is either a bare extension glob ("*.bal") or an exact
-- filename ("Ballerina.toml") — the only two shapes root_direct ever
-- produces, so no general glob engine is needed here.
local function matches_direct_rule(match, name)
  if match:sub(1, 2) == "*." then
    return name:sub(-(#match - 1)) == match:sub(2)
  end
  return name == match
end

-- Sent immediately, one notification per event — unlike core's
-- _watchfiles.lua this does not batch changes behind a 100ms debounce/dedup
-- timer. Root-level watched files (Ballerina.toml, loose .bal files) change
-- far less often than a typical deep tree, so this is an acceptable,
-- deliberate simplification (see docs/proposals/scoped-lsp-file-watch.md).
local function notify(client, fullpath, lsp_change_type)
  client:notify("workspace/didChangeWatchedFiles", {
    changes = { { uri = vim.uri_from_fname(fullpath), type = lsp_change_type } },
  })
end

--- Component B. Builds a synthetic Registration for a RelativePattern group
--- and hands it to core's own (otherwise-public) registration machinery, so
--- the actual recursive watch + kind/pattern matching is identical to what
--- `client/registerCapability` would have done for a real RelativePattern.
---@param id string
---@param base_dir string
---@param group table[]
local function build_registration(id, base_dir, group)
  local watchers = {}
  for _, g in ipairs(group) do
    table.insert(watchers, {
      globPattern = { baseUri = vim.uri_from_fname(base_dir), pattern = g.pattern },
      kind = g.kind,
    })
  end
  return {
    id = id,
    method = "workspace/didChangeWatchedFiles",
    registerOptions = { watchers = watchers },
  }
end

local function start_group(state, name, base_dir, group)
  if state.group_ids[name] or not group or #group == 0 then
    return
  end
  if vim.fn.isdirectory(base_dir) ~= 1 then
    return
  end
  local id = ("ballerina.nvim:%s:%d"):format(name, state.client.id)
  watchfiles.register(build_registration(id, base_dir, group), state.client.id)
  state.group_ids[name] = id
end

local function stop_group(state, name)
  local id = state.group_ids[name]
  if not id then
    return
  end
  watchfiles.unregister({ id = id }, state.client.id)
  state.group_ids[name] = nil
end

--- Component A. Non-recursive watch of the package root's direct children
--- only (`vim._watch.watch` without `uvflags.recursive`, verified to stay
--- non-recursive on macOS — see the proposal doc's "What we already
--- verified"). Bypasses `_watchfiles.lua` entirely because it hardcodes
--- `recursive = true`, which is exactly what must never happen at the
--- package root (that's where target/, .gradle/, etc. live).
local function root_callback(state)
  return function(fullpath, change_type)
    if fullpath == state.root then
      return
    end
    local name = vim.fs.basename(fullpath)
    local lsp_change_type = to_lsp_change_type[change_type]

    -- Component C: modules/ and generated/ appearing or disappearing drives
    -- starting/stopping their scoped recursive watch, independent of
    -- whether the server's own kind mask asks to be notified about it.
    for _, ev in ipairs(state.routed.root_dir_events) do
      if ev.name == name then
        if change_type == watch.FileChangeType.Created then
          start_group(state, name, fullpath, state.routed[name])
        elseif change_type == watch.FileChangeType.Deleted then
          stop_group(state, name)
        end
        if lsp_change_type and kind_matches(ev.kind, lsp_change_type) then
          notify(state.client, fullpath, lsp_change_type)
        end
      end
    end

    if lsp_change_type then
      for _, rule in ipairs(state.routed.root_direct) do
        if matches_direct_rule(rule.match, name) and kind_matches(rule.kind, lsp_change_type) then
          notify(state.client, fullpath, lsp_change_type)
          break
        end
      end
    end
  end
end

--- Starts scoped watching for one client: the root-level non-recursive
--- watcher (A), plus an initial scoped recursive watch (B) for `modules/`
--- and `generated/` if they already exist. Their later creation/deletion is
--- handled dynamically by component A's callback (C).
---@param client vim.lsp.Client
---@param routed table return value of classify()
function M.start(client, routed)
  if active[client.id] then
    return
  end
  -- Empirically confirmed (including for a `bal` workspace member package,
  -- see the proposal's "Workspaces" section): client.workspace_folders is
  -- always the single package root that root_markers resolved to for this
  -- server, so client.root_dir is sufficient — no multi-folder handling
  -- needed.
  local root = client.root_dir
  if not root then
    return
  end

  local state = { client = client, root = root, routed = routed, group_ids = {} }
  active[client.id] = state
  state.root_cancel = watch.watch(root, {}, root_callback(state))

  start_group(state, "modules", vim.fs.joinpath(root, "modules"), routed.modules)
  start_group(state, "generated", vim.fs.joinpath(root, "generated"), routed.generated)
end

--- Stops all watching started by `M.start` for a client. Safe to call more
--- than once (e.g. once per buffer on `LspDetach`) and safe to call for a
--- client that never had watching started.
---@param client_id integer
function M.stop(client_id)
  local state = active[client_id]
  if not state then
    return
  end
  state.root_cancel()
  stop_group(state, "modules")
  stop_group(state, "generated")
  active[client_id] = nil
end

local cleanup_autocmd_registered = false

--- `LspDetach` fires when a client detaches from a buffer, including when
--- the client stops outright — a config-merge-independent place to clean up
--- (unlike client `on_exit`, which a user's own `lsp.config` override could
--- silently replace via the plugin's force-merge, see ballerina.lsp.setup).
--- The check is deferred with vim.schedule: `Client:_on_detach` fires this
--- autocmd *before* removing the buffer from `client.attached_buffers`
--- (see vim/lsp/client.lua), so checking synchronously would never see the
--- last buffer as detached.
local function ensure_cleanup_autocmd()
  if cleanup_autocmd_registered then
    return
  end
  cleanup_autocmd_registered = true
  vim.api.nvim_create_autocmd("LspDetach", {
    callback = function(args)
      local client_id = args.data.client_id
      if not active[client_id] then
        return
      end
      vim.schedule(function()
        local client = vim.lsp.get_client_by_id(client_id)
        if not client or vim.tbl_isempty(client.attached_buffers) then
          M.stop(client_id)
        end
      end)
    end,
  })
end

--- Wires the scoped-watching override into the ballerina client config.
--- Only meant to be called when `lsp.file_watch` is enabled — see
--- ballerina.lsp.setup(), which gates the call.
---@param overrides table mutated in place
function M.apply(overrides)
  overrides.handlers = overrides.handlers or {}
  overrides.handlers["client/registerCapability"] = function(err, params, ctx, config)
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    if client then
      for _, reg in ipairs(params.registrations) do
        if reg.method == "workspace/didChangeWatchedFiles" then
          local routed = M.classify(reg.registerOptions.watchers)
          M.start(client, routed)
          -- Only the unrecognized patterns are left for core's default,
          -- unscoped (crash-risk) handling — everything known is already
          -- covered by our own scoped watches above.
          reg.registerOptions.watchers = routed.unknown
          if #routed.unknown > 0 then
            local patterns = {}
            for _, w in ipairs(routed.unknown) do
              table.insert(
                patterns,
                type(w.globPattern) == "string" and w.globPattern or vim.inspect(w.globPattern)
              )
            end
            vim.notify_once(
              (
                "ballerina.nvim: unrecognized LSP file-watch pattern(s): %s. Falling back to"
                .. " unscoped watching for just these — please report upstream, as this means"
                .. " the crash-prevention scoping in the README no longer covers everything"
                .. " the language server asks to watch."
              ):format(table.concat(patterns, ", ")),
              vim.log.levels.WARN,
              { title = "Ballerina" }
            )
          end
        end
      end
    end
    return vim.lsp.handlers["client/registerCapability"](err, params, ctx, config)
  end
  ensure_cleanup_autocmd()
end

return M

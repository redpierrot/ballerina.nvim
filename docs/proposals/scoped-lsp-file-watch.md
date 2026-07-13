# Proposal: scope LSP file watching to Ballerina's package structure

Status: proposed, not started. Depends on `lsp.file_watch` (shipped — see
`lua/ballerina/lsp.lua`, `CHANGELOG.md` Unreleased), which stays as the
escape hatch regardless of whether this lands.

## Problem

Neovim's LSP client crashes outright (`ENAMETOOLONG` from
`vim._watch.lua:75`, `assert(not err, err)`) when the Ballerina Language
Server registers `workspace/didChangeWatchedFiles` and the workspace
contains a pathologically long or invalid path anywhere under it — observed
in `target/cache/tests_cache/coverage/...` in a Gradle-wrapped stdlib
module, from JaCoCo coverage instrumentation. Full root-cause writeup: see
the "Neovim itself crashing with `ENAMETOOLONG`" entry in README
Troubleshooting.

The mechanism, confirmed by reading Neovim 0.12.4's runtime source
(`lua/vim/lsp/_watchfiles.lua`, `lua/vim/_watch.lua`):

- On macOS, `M._watchfunc` is unconditionally `vim._watch.watch`
  (`_watchfiles.lua:51-52`) — a single recursive `fs_event` handle over the
  whole `base_dir`.
- `base_dir` is derived from `client.workspace_folders`, i.e. the package
  root — **not** from the server's glob pattern. A server registering a
  plain string pattern like `"**/*.bal"` still causes Neovim to recursively
  watch the *entire* workspace folder at the OS level, `target/` included.
- The crash (`assert(not err, err)`, `_watch.lua:75`) fires **before**
  `skip()`/`exclude_pattern` filtering (`_watch.lua:81`) ever runs. So no
  `include_pattern`/`exclude_pattern` configured through the public
  `workspace/didChangeWatchedFiles` registration can prevent it — the crash
  happens at the OS-event layer, before any glob matching.

The only way to avoid the crash is to make sure no watch's `base_dir` is an
ancestor of `target/` (or any other build-cache directory) in the first
place. That requires *scoping* what gets watched, not filtering it after
the fact — which in turn requires understanding Ballerina's actual package
layout instead of treating the workspace as an opaque tree.

## What we already verified

Captured the real registration from Ballerina LS 2201.13.4 (Swan Lake
Update 13), via a headless Neovim session with a `client/registerCapability`
handler that dumps `params` before delegating to the default handler
(reproducible: see the capture script approach below):

```
/**/*.bal              kind=7 (Create+Change+Delete)
/**/modules/*           kind=5 (Create+Delete)
/**/modules             kind=4 (Delete)
/**/generated           kind=4 (Delete)
/**/Ballerina.toml      kind=5 (Create+Delete)
/**/Cloud.toml          kind=5 (Create+Delete)
/**/Dependencies.toml   kind=5 (Create+Delete)
```

All seven are plain-string `globPattern`s (no `baseUri`/`RelativePattern`),
so all seven collapse onto the same single `base_dir` = workspace root —
confirming any one of them is enough to trigger the crash risk, and all
seven need to move off `base_dir = root` for a fix to work.

Also verified empirically (headless Neovim, macOS): `vim._watch.watch(dir,
{}, cb)` **without** `uvflags.recursive = true` genuinely stays
non-recursive — a file created 4 directories deep did not fire the
callback, only a file created directly in the watched directory did. This
was the load-bearing assumption for the design below (macOS FSEvents *does*
honor the non-recursive request; it isn't always-recursive at the OS
level).

## Design, per structural element

Ballerina project structure (as described by the maintainer):

1. Standalone files — no `Ballerina.toml`, not in scope for LSP workspace
   watching at all.
2. Package — root has `Ballerina.toml`. Main module = the package root
   itself (loose `.bal` files there). Submodules live under
   `modules/<module-name>/`. Generated sources live in a `generated/`
   directory inside *any* module (main module: `<root>/generated`;
   submodule: `<root>/modules/<name>/generated`).
3. Workspace — multiple packages under one workspace `Ballerina.toml`; each
   member package is internally structured exactly as (2).

### 1. Root module (`<root>/*`, where `Ballerina.toml` lives)

**Blocker**: none of the 7 patterns can be expressed as a
`RelativePattern` scoped below root, because `_watchfiles.lua` always
requests `recursive = true` regardless of what the registration data says
(`M._watchfunc(base_dir, { uvflags = { recursive = true }, ... })`,
hardcoded, not influenced by the LSP payload). A `RelativePattern` with
`baseUri = root` would therefore still recurse into `target/`.

**Fix**: bypass `_watchfiles.lua`'s registration path entirely for the
root's own direct children. Call `vim._watch.watch(root, {}, callback)`
ourselves (no `recursive` flag) inside our own `client/registerCapability`
handler override (`vim.lsp.config("ballerina", { handlers = {...} })` —
public API; the direct call to `vim._watch.watch` is not, see Risks). In
`callback`, for each direct-child event:

- Matches `*.bal`, `Ballerina.toml`, `Cloud.toml`, or `Dependencies.toml` →
  build an `lsp.FileEvent` and `client:notify('workspace/didChangeWatchedFiles',
  { changes = { ... } })` ourselves. (Given root-level watched files change
  infrequently compared to a deep `node_modules`-style tree, sending
  immediately without core's 100ms debounce/dedup window is an acceptable
  simplification — flag as a deliberate deviation from core behavior, not
  an oversight.)
- Is a directory create/delete matching `modules`, `generated`, or one of
  the excluded build-cache names → drives the dynamic re-scoping in
  "Generated code" below (a new top-level dir needs its own watch started;
  a deleted one needs its watch cancelled).

### 2. Submodules (`<root>/modules/<module-name>/**`)

**Fix**: one `RelativePattern` watcher through the normal, public
`_watchfiles.lua` path — `baseUri = <root>/modules`, recursive (as
`_watchfiles.lua` always does). This single recursive watch, scoped to
`modules/` instead of `root`, correctly and safely covers:

- `.bal` files at any depth inside any submodule (translates `/**/*.bal`).
- A new submodule directory appearing directly under `modules/` (translates
  `/**/modules/*`, kind=Create — this is exactly a first-level child of
  `modules/`, which a recursive watch scoped there reports natively; no
  special-casing needed, unlike the naive "reuse the original pattern
  string" attempt that broke this — see "Rejected approach" below).
- A submodule directory being removed (same pattern, kind=Delete).

This is the directory that makes the domain-aware framing pay off: once we
know `modules/` is a fixed, single, known-depth location (not "`modules`
appearing anywhere in the tree"), the pattern for it collapses to a single
correctly-scoped watch instead of needing a generic glob-rewrite engine.

### 3. Generated code (`<root>/generated`, `<root>/modules/<name>/generated`)

- Submodule-level `generated/` dirs are already covered for free by the
  `modules/` recursive watch in (2) — no separate handling needed.
- Main-module-level `<root>/generated` needs its own watch, structured the
  same way as (2): `RelativePattern` with `baseUri = <root>/generated`,
  once it exists.
- **Open design point**: `generated/` (and, less commonly, `modules/`
  itself) may not exist yet when the client first registers watchers —
  it's created later by a codegen command (`bal openapi`, `bal graphql`,
  `bal persist generate`, etc.). A static one-time enumeration of root's
  children at registration time would silently miss it. The root-level
  non-recursive watcher from (1) already observes the *creation* of a new
  top-level directory named `generated` (or `modules`) as a direct-child
  event — the fix must react to that by dynamically starting a new
  `RelativePattern`/recursive watch for it on the fly (and cancelling it on
  deletion, matching the `/**/generated` and `/**/modules` kind=Delete
  patterns). This dynamic add/remove bookkeeping is the main source of
  state/complexity in the implementation, more than the static routing
  rules above.

### 4. Workspaces (workspace root `Ballerina.toml` + member packages)

**Open question, needs a spike before implementation**: everything above
assumes `client.workspace_folders` resolves to a single package root. For
a workspace, two things are unverified:

- What does `root_markers = { "Ballerina.toml" }` actually resolve to for a
  buffer inside a *member* package of a workspace — the member package's
  own `Ballerina.toml` (nearest ancestor, current plugin behavior), or does
  the Ballerina LS additionally report/require the workspace root via
  dynamic `workspace/workspaceFolders` capability? If it's the former, this
  whole design applies per-member-package unchanged (each member package
  root is watched exactly like a standalone package (2)/(3), and the
  crash-prone `target/` lives inside each member package the same way).
  If it's the latter, `base_dir` for the root-level watch becomes the
  *workspace* root, and root's "direct children" are member package
  directories, not loose `.bal` files — a different, shallower first level
  needs its own translation rule (watch for member-package add/remove,
  then recurse the package-level design into each member).
- Whether the workspace-level `Ballerina.toml` is distinguishable from a
  package-level one (e.g. a `[workspace]` table) matters for correctly
  identifying "is this directory itself a package root that needs its own
  `target/`-exclusion, or a plain subdirectory" when walking into a
  workspace.

**Action**: before implementing, repeat the empirical capture done for the
single-package case (see "What we already verified") against a real `bal`
workspace (`bal new` a workspace, add 2+ member packages, open a file
inside a member package, dump the `client/registerCapability` payload and
inspect `client.workspace_folders`). This determines whether workspaces
need a genuinely different first-level rule or fall out of the
package-level design for free.

## Rejected approach (for context, don't redo)

An earlier attempt tried to generically split each of the 7 server
patterns across root's non-excluded children by reusing the pattern string
verbatim (stripped of its leading `/`) as a `RelativePattern.pattern`. This
breaks for the structural patterns: `/**/modules/*` rescoped to
`baseUri = <root>/modules` becomes `modules/*` relative to itself, which
only matches a `modules/modules/*` path that never exists — silently
losing "new submodule added" detection. It also cannot cover loose
top-level files at all, since `RelativePattern` matching requires
`fullpath` to start with `base_dir .. "/"`, i.e. strictly *inside* the base
— never the base path itself. The design above avoids both problems by
using Ballerina-specific routing rules instead of a generic rewrite, and by
handling root's own children through a separate non-recursive watch rather
than trying to force them through `RelativePattern`.

## Implementation components

- **A — root-level non-recursive watcher.** `vim._watch.watch(root, {},
  callback)`, hand-rolled `workspace/didChangeWatchedFiles` notification
  sending for direct-child file matches. New code, no existing pipeline to
  reuse (`_watchfiles.lua` can't do non-recursive).
- **B — scoped recursive watchers for known subdirectories.** `modules/`
  and `generated/` (main module), each as a normal
  `client/registerCapability`-rewritten `RelativePattern` registration
  through the existing public `_watchfiles.lua` path (no bypass needed
  here — this part *is* just configuration of the standard mechanism).
- **C — dynamic add/remove.** Component A's callback drives starting/
  cancelling component B's watches as `modules/`/`generated/` are
  created/deleted after the client has already started.
- **D — pattern → routing table**, keyed to the 7 exact strings captured
  above. Needs an explicit, loud fallback for any watcher pattern that
  doesn't match a known entry (e.g. `vim.notify` once, and fall back to
  leaving that one pattern unscoped — i.e. accept the crash risk for that
  specific pattern only, rather than silently dropping coverage). This
  keeps a future Ballerina LS change *visible* instead of silently
  degrading file-watching.
- **E — workspace routing**, blocked on the open question in "Workspaces"
  above; likely an additional first-level table alongside D once resolved.

## Risks / fragility (be upfront about these in the PR description)

- Depends on `vim._watch.watch` directly (component A) — `vim._watch` is
  an underscore-prefixed, explicitly private Neovim module. The
  `client/registerCapability` handler override used for component B is
  public (`:h lsp-handler-resolution`); the direct low-level call in
  component A is not. Both are reachable and stable-*enough* in practice
  (core's own `:checkhealth vim.lsp` already detects and labels a
  custom `_watchfunc`, i.e. this class of override is anticipated), but
  neither carries a stability guarantee across Neovim versions.
- Depends on the exact glob strings Ballerina LS 2201.13.4 sends — an
  undocumented, unversioned contract with `bal`. Component D's loud
  fallback is the mitigation, not a fix.
- `client/registerCapability` handler overrides are global to the *client*
  config, not scoped to just this one method — must delegate every other
  registration method through to `vim.lsp.handlers['client/registerCapability']`
  unchanged, and be careful not to regress unrelated dynamic registrations
  (formatting, code actions, etc.) for the ballerina client.
- Component A's hand-rolled notification sending diverges from core's
  debounce/dedup behavior (see "Root module" above) — acceptable for low
  event volume, but worth a code comment explaining the deviation is
  deliberate.

## Testing plan

- CI has no real `bal` binary (per `CONTRIBUTING.md`, LSP paths are
  exercised manually) — so automated tests need a fake LSP peer, not a
  live Ballerina LS. Build a `tests/run.lua` case using the exact captured
  JSON payload above as a fixture (same style as the existing `dap` test's
  fake-`dap`-table pattern): drive `client/registerCapability` with it
  through the real handler and assert on which `base_dir`s ended up
  watched (or, more simply, assert the routing table's pure function
  output for each of the 7 known patterns, independent of a live client).
- Manual verification checklist (needs real `bal`, run before merging):
  1. Single package, loose `main.bal` at root: edit the file *outside*
     Neovim (e.g. `echo >> main.bal` from a shell), confirm the LS's
     diagnostics/completions reflect it without restarting.
  2. Add a submodule via `bal add` while Neovim is open with a buffer from
     the package; confirm the LS resolves symbols from it without restart.
  3. Run `bal openapi`/`bal graphql` (whichever generates into
     `generated/`) while Neovim is open; confirm the newly generated
     `.bal` file's symbols resolve without restart.
  4. Reproduce the original crash scenario (Gradle-wrapped module,
     `bal test --code-coverage`) with this fix active; confirm Neovim
     does not crash.
  5. Workspace scenario, once the spike in "Workspaces" resolves the open
     question — repeat 1-3 with a member package.

## Sizing / sequencing

Not a quick config change — treat as its own PR, separate from the shipped
`lsp.file_watch` toggle. Suggested order:
1. Spike: workspace `client.workspace_folders` behavior (resolves the open
   question in "Workspaces" and may reshape component E).
2. Component D (pure routing-table function) + its unit tests — no live
   client needed, cheapest to get right first.
3. Component B (scoped recursive watchers via the public handler
   override) — exercises D against the real registration path.
4. Component A + C (root-level non-recursive watcher, dynamic add/remove)
   — the largest, most novel piece.
5. Manual verification checklist above, then update README Troubleshooting
   to describe the new default behavior (this fix, once landed, likely
   makes `lsp.file_watch = false` unnecessary for most users — but keep it
   as the fallback for whatever this design doesn't cover, e.g. non-Gradle
   build tools with their own pathological cache paths).

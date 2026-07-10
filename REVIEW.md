# ballerina.nvim — Review Findings & Action Items

Reviewed: 2026-07-10. Scope: architecture, code quality, missing features,
documentation, publishing. Each item is written to be independently
actionable by an agent: it names the files involved, what to change, and how
to verify. Priorities: **P1** = fix before publishing, **P2** = fix soon
after, **P3** = nice to have.

Overall assessment: the plugin is small, idiomatic, and well-commented. The
architecture (thin `init.lua`, config module, lazy `require`s, idempotent LSP
registration) is sound for its size. The findings below are mostly
correctness bugs, convention gaps, and pre-publish polish — nothing
structural needs a rewrite.

---

## 1. Architecture

### A1 (P2) — Ship the LSP config as an `lsp/ballerina.lua` runtime file
**Files:** `lua/ballerina/lsp.lua`, `ftdetect/ballerina.lua`, new `lsp/ballerina.lua`

Neovim 0.11's native convention (and what nvim-lspconfig 2.x itself does) is
to put the server definition in an `lsp/<name>.lua` file on the runtimepath
that returns a `vim.lsp.Config` table, and only call
`vim.lsp.enable("ballerina")` from Lua. Note that **nvim-lspconfig already
ships an essentially identical `lsp/ballerina.lua`** (`bal
start-language-server`, `Ballerina.toml` root marker); using the same
mechanism means the two merge cleanly by name instead of racing, and users
can override any field with a plain `vim.lsp.config("ballerina", {...})` call.

- Create `lsp/ballerina.lua` returning `{ cmd = ..., filetypes = {"ballerina"}, root_markers = {"Ballerina.toml"} }`.
- Reduce `lua/ballerina/lsp.lua` to applying user overrides (`vim.lsp.config`) and `vim.lsp.enable`.
- Verify: open a `.bal` file, `:checkhealth vim.lsp` shows one `ballerina` client attached; also test with nvim-lspconfig installed simultaneously.

### A2 (P1) — `ftdetect/` does eager work at startup for every Neovim launch
**Files:** `ftdetect/ballerina.lua:13`, `lua/ballerina/lsp.lua:14`

`ftdetect/ballerina.lua` calls `require("ballerina.lsp").setup()`, which
calls `util.bal_cmd()` → `vim.fn.exepath("bal")` **at startup**, even in
sessions that never touch Ballerina, and even when the plugin is not
lazy-loaded. ftdetect files should only do filetype detection. With A1 in
place this call can be deleted entirely (the `lsp/` file is read lazily);
otherwise make `cmd` a function so the binary is resolved only when the
server actually starts:

```lua
cmd = function(dispatchers)
  return vim.lsp.rpc.start({ require("ballerina.util").bal_cmd(), "start-language-server" }, dispatchers)
end
```

(or simply resolve inside an `on_setup`/deferred path). Verify: `nvim --startuptime` shows no `exepath` cost; opening a text file never touches ballerina modules.

### A3 (P1) — `bal` fallback path is macOS-only and never validated
**Files:** `lua/ballerina/util.lua:17-21`

`exepath("bal") == ""` falls back to `/Library/Ballerina/bin/bal`, which only
exists on macOS. Linux installer uses `/usr/lib/ballerina/bin/bal`; Windows
uses `C:\Program Files\Ballerina\bin\bal.bat`. The result is also cached
forever even when the file doesn't exist, so every consumer (LSP, format)
fails with an opaque ENOENT.

- Try a platform-appropriate list of fallback candidates and check `vim.fn.executable()` on each.
- If nothing is found, return `nil` and let callers surface a single clear `vim.notify` ("bal not found; install Ballerina or set `bal_cmd`") instead of crashing (see C3).
- Verify: rename `bal` off PATH, open a `.bal` file and save — exactly one friendly warning, no stack traces.

### A4 (P2) — No extension point for LSP settings
**Files:** `lua/ballerina/lsp.lua`, `lua/ballerina/config.lua`, README

Users cannot pass `capabilities` (nvim-cmp/blink.cmp), `on_attach`,
`init_options`, or `settings` through the plugin. With the native API they
can call `vim.lsp.config("ballerina", {...})` themselves — but nothing tells
them that. Either accept an opaque `lsp.config` table that is merged into the
registration, or (simpler) document the `vim.lsp.config("ballerina", {...})`
escape hatch in README and `doc/ballerina.txt`. Verify: documented example
sets `capabilities` and it appears in `:lua =vim.lsp.config.ballerina`.

### A5 (P1) — Decouple the format action from the `format_on_save` gate
**Files:** `lua/ballerina/format.lua:29-35`

`M.format()` early-returns when `format_on_save = false`, so the module
cannot be reused for a manual `:BallerinaFormat` command (F1). Move the
`format_on_save` / `b:ballerina_disable_format` checks into the autocmd
callback (`ftplugin/ballerina.lua`), keeping `M.format(bufnr)` an
unconditional "format now" primitive. Verify: with `format_on_save = false`,
`:BallerinaFormat` still works and saving does nothing.

---

## 2. Code Review (bugs & conventions)

### C1 (P1) — Syntax file keyword list diverges from the compiler's
**Files:** `syntax/ballerina.vim:29-40`

Full audit against the Ballerina compiler's `LexerTerminals.java` (102 lexer
keywords, master as of 2026-07-10):

| Keyword | Status | Fix |
| --- | --- | --- |
| `var` | **missing** (`var x = …`) | add to `balType` |
| `type` | **missing** (`type Person record {…}`) | add as `balTypedef` → `Typedef` |
| `from` | **missing** (query expressions; line-28 comment claimed it was covered) | add to `balKeyword` |
| `natural` | **missing** (natural expressions, newer Swan Lake) | add to `balKeyword` |
| `re` | **missing** (regexp template prefix) | context match `\<re\ze\s*\`` only — a bare keyword would highlight every identifier named `re` |
| `version` | **obsolete** — import versioning was removed from the language; no longer in LexerTerminals | remove from `balKeyword` |
| `group`, `collect` | not in LexerTerminals but **correct to keep**: contextual query keywords promoted by the parser | keep, with a comment |
| `self` | reserved name, not a lexer keyword | keep as Constant |

Also from the grammar: float/decimal literals accept `f|F|d|D` suffixes
(`1.0f`, `2d`) — extend the `balNumber` decimal pattern.

Verify: `grep -oE '= "[a-z0-9]+";' LexerTerminals.java` set-diffed against
the `syntax keyword` lists is empty in both directions (modulo the
documented contextual/obsolete exceptions above).

### C2 (P1) — Package-wide format leaves other open buffers stale
**Files:** `lua/ballerina/format.lua:46-65`

`bal format` in the package root rewrites **every** file in the package, but
only the saved buffer is reloaded. Any other `.bal` buffer from the same
package now differs from disk: the user gets W12 "file changed on disk"
prompts, or worse, silently writes back stale, unformatted content over the
formatted file. After a successful package-level format, reload every loaded,
unmodified buffer whose name is under `root` (reuse `reload_from_disk`, with
the same changedtick guard per buffer). Verify: open two files from one
package, edit and save one — the other updates without W12 and without losing
its window view.

### C3 (P1) — Saving with a missing `bal` binary throws an error
**Files:** `lua/ballerina/format.lua:46`

`vim.system` raises (ENOENT) when the command isn't executable, so with `bal`
absent, **every save of a .bal file produces a Lua stack trace**. Wrap the
`vim.system` call in `pcall` and emit one `vim.notify` warning (once per
session, not per save). Pairs with A3. Verify: `bal_cmd = "/nonexistent"`,
save a file → single warning, no error.

### C4 (P2) — Indent comment-stripper mishandles Ballerina quoted identifiers
**Files:** `lua/ballerina/indent.lua:23`

`strip_line_comment` treats `'` as a string opener, but Ballerina has no
single-quoted strings — a lone `'` introduces a quoted identifier
(`int 'from = 5;`) with **no closing quote**. On such lines the rest of the
line is considered "inside a string", so a trailing `// comment` containing
`{` or `(` is not stripped and corrupts the indent calculation. Remove `'`
from the string-delimiter set (keep `"`). Verify: line `int 'from = 5; // {`
followed by a new line does not add an indent level.

### C5 (P2) — ftplugin conventions: no `b:undo_ftplugin`, no augroup
**Files:** `ftplugin/ballerina.lua`

Standard ftplugin contract: set `b:undo_ftplugin` so `:set ft=` away from
ballerina restores the buffer's options and removes the autocmd. Also put the
`BufWritePost` autocmd in a named `augroup` (e.g. `ballerina_format_<bufnr>`
or one group with buffer-local clearing) so it is discoverable in `:autocmd`
and cleaned up on undo. Verify: `:set ft=lua` on a .bal buffer restores
`shiftwidth`/`indentexpr` and saving no longer formats.

### C6 (P2) — Format autocmd is only registered if `format_on_save` was true at buffer-open time
**Files:** `ftplugin/ballerina.lua:23`

The ftplugin snapshots `config.format_on_save` when the buffer opens. If the
user's `setup()` runs after the first `.bal` buffer's ftplugin (plausible
under lazy-loading), or they toggle the option at runtime, existing buffers
keep the stale behavior. Since the callback (post-A5) re-checks the option
anyway, register the autocmd unconditionally and gate inside the callback.
Same reasoning applies to the `indent` block — at minimum document that
`indent` applies to buffers opened after `setup()`. Verify: open a .bal file,
then `setup({ format_on_save = true })` from `:lua`, save → formats.

### C7 (P3) — Config polish
**Files:** `lua/ballerina/config.lua`, `lua/ballerina/init.lua`

- Add LuaCATS annotations (`---@class ballerina.Config`, `---@field bal_cmd string?` …) so lua-language-server users get completion on `opts`; reference the class from `init.lua`'s `setup` param instead of `table|nil`.
- Optionally `vim.validate` the option types and warn on unknown keys.

### C8 (P3) — `resolved_cmd` cache never invalidates
**Files:** `lua/ballerina/util.lua:13`

If `bal` is installed mid-session, the cached fallback sticks until restart.
Low impact; either don't cache negative results or expose the resolution in
`:checkhealth` (F3) so the state is at least visible.

### C9 (P1) — No tests, no CI, no lint config
**Files:** new `.github/workflows/ci.yml`, `stylua.toml`, `.luacheckrc` (or `selene.toml`), `spec/` or `tests/`

Reference plugins (harpoon, telescope.nvim, mini.nvim ecosystem) all ship:
- **stylua** with a committed `stylua.toml` (2-space indent matches current style) and a CI check.
- **luacheck** or **selene** with `vim` as a declared global.
- **Tests**: `busted` via `nvim-busted-action`/luarocks (mrcjkb's approach) or `plenary.nvim`/`mini.test`. Highest-value first tests: `indent.indentexpr` (pure function — table-driven cases including C4), `config.setup` merging, `util.bal_cmd` resolution with a fake `$PATH`.
- A `Makefile` (or `justfile`) with `test` / `lint` / `fmt` targets.
- CI matrix: stable Neovim ≥ 0.11 and nightly.

Verify: CI green on the repo before the first tag.

---

## 3. Missing Features

### F1 (P1) — `:BallerinaFormat` user command
Manual, on-demand format (depends on A5). Buffer-local command created in the
ftplugin, or a global command in a new `plugin/ballerina.lua`. Consider
`:BallerinaFormatToggle` (or `:BallerinaFormat!`) to flip
`b:ballerina_disable_format`.

### F2 (P2) — `bal run` / `bal test` / `bal build` commands
Async `:BallerinaRun`, `:BallerinaTest`, `:BallerinaBuild` on the enclosing
package (reuse `vim.fs.root` + `vim.system`), output to a terminal split or
quickfix (Ballerina's `filename:(line:col,line:col)` diagnostics can be
parsed into `errorformat`). This is the biggest functional gap vs. what the
VS Code extension offers. Keep scope modest: run/test/build only, no debugger.

### F3 (P1) — `:checkhealth ballerina`
New `lua/ballerina/health.lua` with `M.check()`: report Neovim ≥ 0.11,
resolved `bal` path (or actionable error), `bal version` output, whether the
LSP client is registered. This is the standard first-line support tool users
expect and cuts issue-report noise dramatically for a new plugin.

### F4 (P3) — Neotest adapter / snippets / treesitter
Explicitly out of scope for v0.1 — record as roadmap items in the README.
There is still no treesitter grammar for Ballerina; the README already says
so. If one appears, the syntax file and indentexpr become fallbacks.

---

## 4. Documentation

### D1 (P1) — Fix the repo URL in README
**Files:** `README.md:39`

Install snippet says `"thisaruguruge/ballerina.nvim"`. The plugin will be
published at **`redpierrot/ballerina.nvim`** (repo already created) — update
the lazy.nvim spec and any future references to that owner/name.

### D2 (P1) — README gaps
**Files:** `README.md`

Currently good on "why" (grammar notes, format rationale) but missing:
- **Prerequisites/how-to-install-Ballerina**: link https://ballerina.io/downloads/, mention `brew install ballerina`; note the distribution bundles its own JRE (no separate Java needed) and which Swan Lake versions were tested (2201.13.x).
- **Install instructions beyond lazy.nvim**: at least vim-plug/packer or plain `:h packages` form, and a note that `setup()` must be called manually there.
- **Usage / what-you-get section**: small examples — open a `.bal` file → LSP attaches; Neovim 0.11 default LSP mappings that now work (`K`, `grn`, `gra`, `grr`, `gd`, `[d`/`]d`); a format-on-save example; how to set `capabilities` for a completion plugin (pairs with A4).
- **Troubleshooting**: `:checkhealth ballerina` (after F3), `:checkhealth vim.lsp`, common "bal not on PATH from GUI Neovim" issue.
- **Interop note**: nvim-lspconfig also defines `ballerina`; explain they coexist/merge (pairs with A1).
- Badges (CI, license), a screenshot/GIF, and a short roadmap (F2/F4).

### D3 (P2) — Vimdoc fixes
**Files:** `doc/ballerina.txt`

- `|ballerina.setup()|` on line 30 is a **broken tag link** — no `*ballerina.setup()*` tag is defined anywhere. Add the tag next to the setup section or change the link.
- Add per-option tags (`*ballerina.nvim-bal_cmd*` etc.) so `:h ballerina.nvim-format_on_save` works.
- Add sections for commands (F1/F2) and health (F3) as they land; add a License section.
- Verify: `:helptags doc/` then `:h ballerina<Tab>` — every tag resolves, no duplicates.

### D4 (P2) — Community files
Add `CHANGELOG.md` (keep-a-changelog format; release-please can maintain it,
see P4), and optionally `CONTRIBUTING.md` (how to run tests/lints — depends
on C9). `LICENSE` (MIT, 2026) and `.gitignore` (`doc/tags`) are already
correct.

---

## 5. Publishing (`redpierrot/ballerina.nvim`)

### P1 (P1) — First push & repo metadata
- Push to `github.com/redpierrot/ballerina.nvim` (repo exists). Decide default branch (`main`) and merge/rename the current local `dev` history accordingly.
- Set the repo **description** and **topics**: `neovim`, `neovim-plugin`, `ballerina`, `lua`, `lsp`. Topics drive discovery — neovimcraft and dotfyle index GitHub by these topics.
- Confirm GitHub detects the MIT license (it will, the file is standard).

### P2 (P1) — Versioned releases
Tag semver releases starting at `v0.1.0` and create GitHub Releases. Optionally
automate with **release-please** (conventional commits → automated version
PRs + CHANGELOG), which composes with P3 below.

### P3 (P2) — LuaRocks
Publish via the **luarocks-tag-release** GitHub Action (nvim-neorocks/lumen-oss):
1. Create a LuaRocks account (GitHub sign-in) at luarocks.org and generate an API key.
2. Add it as the `LUAROCKS_API_KEY` Actions secret.
3. Add a workflow triggered on tag push; the action generates the rockspec from repo metadata (this is why P1's description/topics/license matter), test-installs, and uploads. Public repos only — fine here.
This makes the plugin installable by rocks.nvim/lazy.nvim's luarocks support.

### P4 (P2) — Directory listings & announcements
- **awesome-neovim**: one PR, title exactly `` Add `redpierrot/ballerina.nvim` ``, follow their description rules (no emojis, don't say "plugin"/"Neovim" unless essential, run `./scripts/readme-check.sh`). Category: *Programming Languages Support*.
- **dotfyle / neovimcraft**: indexed automatically once topics (P1) are set and/or the awesome-neovim PR lands.
- Announce on **r/neovim** (flair: "made this") and in the **Ballerina community** (Discord/discourse) — the audience most likely to actually use it.

### P5 (P3) — Upstream consideration
nvim-lspconfig already carries `lsp/ballerina.lua`, so no upstreaming is
needed for LSP. If the Ballerina platform team maintains an editor-tools
page, ask them to list ballerina.nvim alongside the VS Code extension.

---

## Implementation status (2026-07-10)

**Implemented and verified** (15-case test suite passes via `make test`;
end-to-end format/reload/missing-`bal` paths verified against Ballerina
2201.13.4; ftplugin/undo_ftplugin/commands/syntax smoke-tested headless):

- Architecture: A1, A2, A3, A4, A5
- Code: C1 (full audit above), C2, C3, C4, C5, C6, C7, C8, C9
- Features: F1, F2, F3 (F4 recorded as README roadmap)
- Docs: D1, D2, D3, D4
- Publishing: P3 workflow committed (`.github/workflows/release.yml`)

Post-review additions (from the "missing pieces vs. mature language
plugins" comparison, all implemented and e2e-verified):

- **DAP debugging** (`lua/ballerina/dap.lua`): nvim-dap adapter via
  `bal start-debugger-adapter` + 3 launch configs and attach. Request
  attribute names verified against the adapter sources in ballerina-lang
  (`script`, `ballerina.home`, `ballerina.command`, `scriptArguments`,
  `debugTests`, `debuggeeHost`/`debuggeePort`).
- **Quickfix integration**: run/test/build output parsed into quickfix with
  full ranges (`%e`/`%k`); `compiler/ballerina.vim` reads the same
  errorformat from `cli.errorformat` (sync asserted by a test).
- **Command arguments**: `:BallerinaRun/Test/Build [args]` with `--`
  splitting options (before target) from program args (after target).
- **`$BALLERINA_HOME` detection**: checked after PATH, before the
  hardcoded install locations (the official installers export it).

**Remaining — external steps only, in order:**

1. **P1**: push to `github.com/redpierrot/ballerina.nvim`, set description +
   topics (`neovim`, `neovim-plugin`, `ballerina`, `lua`, `lsp`).
2. **P2**: tag `v0.1.0` once CI is green.
3. **P3**: create the luarocks.org API key and add it as the
   `LUAROCKS_API_KEY` repo secret (the workflow is already in place).
4. **P4**: awesome-neovim PR (`` Add `redpierrot/ballerina.nvim` ``),
   r/neovim + Ballerina community announcements.
5. Optional polish: a screenshot/GIF for the README; release-please if
   automated changelogs are wanted.

# ballerina.nvim

[![CI](https://github.com/redpierrot/ballerina.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/redpierrot/ballerina.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Ballerina support for Neovim: syntax highlighting, LSP setup, package-aware
format-on-save, auto-indent, and `bal` run/test/build commands — the pieces
missing since [vim-ballerina](https://github.com/martskins/vim-ballerina)
only covers syntax highlighting and there's no treesitter grammar for
Ballerina yet.

## Features

- **Syntax highlighting** — `syntax/ballerina.vim`, with keyword and type
  lists matching the Ballerina compiler's `LexerTerminals.java` (including
  contextual query keywords like `group`/`collect` and the `re` regexp
  template prefix). See [Grammar notes](#grammar-notes) below.
- **LSP** — ships a native `lsp/ballerina.lua` definition
  (`bal start-language-server`) and enables it via `vim.lsp.enable()`.
  Hover, go-to-definition, rename, code actions, diagnostics, completion —
  everything the Ballerina language server provides.
- **Format on save** — runs `bal format` after every save. `bal format`
  can't format a single file that belongs to a package (it errors with
  `"belongs to a Ballerina package"`), so for package files this formats
  the whole enclosing package and reloads every affected buffer from disk;
  standalone `.bal` scripts are formatted directly.
- **Auto-indent** — a small brace/paren-aware `indentexpr`. `cindent` was
  tried and rejected: it misreads module-qualified calls like
  `io:println(...)` as C jump labels (`identifier:`) and de-indents them to
  column 0.
- **Commands** — `:BallerinaFormat`, `:BallerinaRun`, `:BallerinaTest`,
  `:BallerinaBuild` (with argument passthrough), `:BallerinaFormatToggle`.
- **Quickfix** — compiler diagnostics from `:BallerinaBuild`/`Run`/`Test`
  land in the quickfix list (`:cnext` and friends), and a
  `:compiler ballerina` definition makes plain `:make` work too.
- **Debugging** — if [nvim-dap](https://github.com/mfussenegger/nvim-dap)
  is installed, the Ballerina debug adapter and launch/attach
  configurations are registered automatically. See
  [Debugging](#debugging).
- **Health check** — `:checkhealth ballerina`.

## Requirements

- **Neovim >= 0.11** (uses `vim.lsp.config`/`vim.lsp.enable` and
  `vim.system`)
- **The [Ballerina](https://ballerina.io) distribution** — grab it from
  [ballerina.io/downloads](https://ballerina.io/downloads/) or
  `brew install ballerina`. The distribution bundles its own Java runtime,
  so no separate JDK is needed. Developed against Swan Lake 2201.13.x;
  anything with `bal start-language-server` and `bal format` should work.
- `bal` on your `PATH`. If it isn't (common when GUI Neovim is launched
  outside a login shell), the plugin also probes the official installers'
  locations, or you can set `bal_cmd` explicitly (see below).

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "redpierrot/ballerina.nvim",
  ft = "ballerina",
  opts = {},
}
```

With [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'redpierrot/ballerina.nvim'
```

```lua
-- after plug#end():
require("ballerina").setup({})
```

Or with Neovim's built-in package support (`:h packages`):

```sh
git clone https://github.com/redpierrot/ballerina.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/ballerina.nvim
```

Calling `setup()` (or passing `opts`) is optional — the plugin works with
its defaults as soon as a `.bal` file is opened. Call it only to override
options.

## Quick start

Open any `.bal` file. You get 4-space indentation, syntax highlighting, and
the language server attaches automatically (first start takes a few seconds
while the JVM warms up — watch `:checkhealth vim.lsp`).

Neovim's default LSP mappings then work out of the box:

| Mapping | Action |
| --- | --- |
| `K` | Hover documentation |
| `grn` | Rename |
| `gra` | Code action |
| `grr` | References |
| `gri` | Implementation |
| `gO` | Document symbols |
| `[d` / `]d` | Previous/next diagnostic |
| `<C-x><C-o>` | Omni completion |

Buffer-local commands in `.bal` buffers:

| Command | Action |
| --- | --- |
| `:BallerinaFormat` | Format the file (or its enclosing package) now |
| `:BallerinaFormatToggle` | Toggle format-on-save for this buffer |
| `:BallerinaRun [args]` | `bal run` the package/script in a terminal split |
| `:BallerinaTest [args]` | `bal test` in a terminal split |
| `:BallerinaBuild [args]` | `bal build` in a terminal split |

The run/test/build commands accept arguments: everything before a literal
`--` is passed as CLI options (before the target), the `--` and everything
after it as program arguments (after the target), matching
`bal run [options] [target] [-- program-args]`:

```vim
:BallerinaTest --tests fooTest
:BallerinaRun -- 8080 --verbose
```

When the command finishes, any compiler diagnostics in its output are
parsed into the quickfix list — `:copen` / `:cnext` to jump between them.
Prefer classic `:make`? `:compiler ballerina` sets `makeprg`/`errorformat`
to the same patterns.

Saving a file runs `bal format` in the background and reloads the buffer(s)
when it finishes. To turn that off for one buffer, use
`:BallerinaFormatToggle` (or set `vim.b.ballerina_disable_format = true`);
to turn it off everywhere, set `format_on_save = false`.

## Configuration

Defaults:

```lua
require("ballerina").setup({
  -- Path to the `bal` binary. nil = auto-detect: PATH, then
  -- $BALLERINA_HOME/bin/bal, then the known install locations used by the
  -- official installers.
  bal_cmd = nil,
  -- Run `bal format` after saving a .bal file.
  format_on_save = true,
  -- Use the bundled indentexpr.
  indent = true,
  lsp = {
    enabled = true,
    root_markers = { "Ballerina.toml" },
    -- Let the server ask Neovim to watch the workspace for external file
    -- changes (git checkouts/pulls, .bal source generated by `bal
    -- openapi`/`bal graphql`/`bal grpc`/etc. run outside Neovim). Scoped to
    -- Ballerina's package structure so a build cache (target/, .gradle/)
    -- is never watched. On by default; turn off only if you hit a case the
    -- scoping doesn't cover, see Troubleshooting below.
    file_watch = true,
    -- Extra fields merged into the LSP client config (:h vim.lsp.Config),
    -- e.g. capabilities, settings, init_options.
    config = nil,
  },
  dap = {
    -- Register the debug adapter/configurations when nvim-dap is installed.
    enabled = true,
  },
})
```

For example, to pass completion capabilities from
[blink.cmp](https://github.com/Saghen/blink.cmp) or
[nvim-cmp](https://github.com/hrsh7th/nvim-cmp):

```lua
require("ballerina").setup({
  lsp = {
    config = {
      capabilities = require("blink.cmp").get_lsp_capabilities(),
      -- capabilities = require("cmp_nvim_lsp").default_capabilities(),
    },
  },
})
```

Equivalently, since the server is a native `vim.lsp.config` definition, you
can override any field directly without going through `setup()`:

```lua
vim.lsp.config("ballerina", {
  capabilities = require("blink.cmp").get_lsp_capabilities(),
})
```

### Using nvim-lspconfig?

[nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) ships an
equivalent `ballerina` definition. That's fine: Neovim merges same-named
`lsp/` definitions, and anything set via `vim.lsp.config("ballerina", ...)`
wins over both. You will not get two clients.

## Debugging

With [nvim-dap](https://github.com/mfussenegger/nvim-dap) installed,
opening a `.bal` file registers the Ballerina debug adapter (the same
`bal start-debugger-adapter` the VS Code extension uses) plus four
configurations:

- **Debug Ballerina program** — debug the current package/script
- **Debug Ballerina program (prompt for arguments)**
- **Debug Ballerina tests** — `bal test` under the debugger
- **Attach to running program** — for processes started with
  `bal run --debug <port>`

Set a breakpoint and `:lua require("dap").continue()` (or your usual dap
keymaps). No launch.json needed. The first launch takes several seconds —
the adapter and the debuggee are JVM processes.

## Troubleshooting

- Run `:checkhealth ballerina` — it verifies the Neovim version, locates
  `bal` (and prints which one), and reports the LSP client state.
- The language server not attaching is almost always `bal` missing from the
  environment Neovim was launched in. Set `bal_cmd` to an absolute path if
  auto-detection fails.
- `:checkhealth vim.lsp` shows the client log if the server starts and then
  crashes.
- Neovim itself crashing with `ENAMETOOLONG` from `vim._watch`, mentioning a
  path under a compiler/Gradle build cache (`target/`, `.gradle/`, ...): a
  known Neovim limitation on macOS, where LSP workspace file watching uses a
  single recursive `fs_event` over the whole project by default. It has no
  way to exclude subdirectories at the OS level, so if a build ever produces
  a pathologically long or invalid path there (observed with JaCoCo
  code-coverage instrumentation in Gradle-wrapped builds), Neovim asserts
  and crashes outright — before the change even reaches this plugin's LSP
  client. This plugin works around it by scoping what gets watched to
  Ballerina's own package structure (`Ballerina.toml`, loose `.bal` files,
  `modules/`, `generated/`) instead of the whole workspace folder, so a
  build cache is never watched, recursively or otherwise — see
  `lua/ballerina/lsp_watch.lua` and
  `docs/proposals/scoped-lsp-file-watch.md` for the mechanism. If you hit a
  crash anyway (e.g. a Ballerina LS version that registers watch patterns
  this plugin doesn't recognize — it warns loudly when that happens), set
  `lsp.file_watch = false` as a full opt-out; the tradeoff is the server no
  longer auto-discovers files it didn't get through Neovim (git
  checkouts/pulls, `.bal` source generated by `bal openapi`/`bal
  graphql`/`bal grpc`/etc. run outside Neovim) — open or re-save the
  generated file, or `:LspRestart`, to pick those up.

## Grammar notes

The official grammar (`ballerina.YAML-tmLanguage`) is a **TextMate**
grammar consumed by the VS Code extension, forked from the same scaffold
used for TypeScript's grammar. Most of its complexity is generic
disambiguation machinery (arrow functions vs. comparisons vs. generics)
that doesn't reflect anything Ballerina-specific and can't be expressed in
Vim's regex engine (no recursive patterns). Rather than attempt a
byte-for-byte port, this plugin takes the authoritative keyword/type lists
from the compiler's `LexerTerminals.java` (plus the parser-level contextual
keywords like `group` and `collect`) and implements conventional
`:syntax keyword`/`:syntax match`/`:syntax region` rules around them — the
same level of coverage most language syntax files have.

## Roadmap

- [neotest](https://github.com/nvim-neotest/neotest) adapter for `bal test`
- Snippets
- Treesitter support, if/when a Ballerina grammar appears

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). In short: `make test`, `make lint`,
`make fmt` — CI runs the same checks.

## License

[MIT](LICENSE)

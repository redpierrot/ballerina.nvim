# ballerina.nvim

[![CI](https://github.com/redpierrot/ballerina.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/redpierrot/ballerina.nvim/actions/workflows/ci.yml)
[![LuaRocks](https://img.shields.io/luarocks/v/thisarug/ballerina.nvim)](https://luarocks.org/modules/thisarug/ballerina.nvim)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Neovim >= 0.11](https://img.shields.io/badge/Neovim-%3E%3D0.11-blueviolet)](#requirements)

Ballerina support for Neovim — syntax highlighting, LSP, format-on-save,
auto-indent, and `bal run`/`test`/`build`, in one plugin.

![ballerina.nvim demo: syntax highlighting, an inline diagnostic, and a compile error landing in the quickfix list](media/demo.gif)

**[Features](#features)** · **[Requirements](#requirements)** · **[Installation](#installation)** · **[Quick start](#quick-start)** · **[Commands](#commands)** · **[Configuration](#configuration)** · **[Debugging](#debugging)** · **[Troubleshooting](#troubleshooting)** · **[Grammar notes](#grammar-notes)** · **[Roadmap](#roadmap)** · **[Related](#related)** · **[Contributing](#contributing)** · **[License](#license)**

Why not just [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)? LSP
is only one part of what this plugin does — package-aware format-on-save, a
brace-aware `indentexpr`, `:Ballerina{Run,Test,Build}` with quickfix
integration, and DAP debugging all ship alongside the LSP config, so
swapping in `nvim-lspconfig` for the LSP piece alone still leaves those out.
(If you already use `nvim-lspconfig`, it's not a conflict either way — see
[Using nvim-lspconfig?](#lsp-capabilities) under Configuration.)

## Features

- **Syntax highlighting** matching the Ballerina compiler's keyword/type
  lists ([details](#grammar-notes))
- **LSP** via a native `vim.lsp.config` definition — hover, completion,
  rename, code actions, diagnostics, the works
- **Format on save**, package-aware (`bal format` can't format a single
  file that belongs to a package, so the plugin formats the whole package
  and reloads affected buffers)
- **Auto-indent** — a brace/paren-aware `indentexpr` (`cindent` misreads
  `io:println(...)` as a C jump label)
- **`:Ballerina{Run,Test,Build,Format}`** commands, with compiler
  diagnostics landing in the quickfix list
- **Debugging** via [nvim-dap](https://github.com/mfussenegger/nvim-dap),
  auto-registered if it's installed
- **`:checkhealth ballerina`**

## Requirements

- Neovim >= 0.11
- The [Ballerina](https://ballerina.io) distribution —
  [ballerina.io/downloads](https://ballerina.io/downloads/) or
  `brew install ballerina` (bundles its own JVM, no separate JDK needed).
  Developed against Swan Lake 2201.13.x.
- `bal` on your `PATH`. If it isn't (common when GUI Neovim is launched
  outside a login shell), the plugin also checks `$BALLERINA_HOME` and the
  official installer locations — see
  [Setting the Ballerina distribution](#setting-the-ballerina-distribution).

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "redpierrot/ballerina.nvim",
  ft = "ballerina",
  opts = {},
}
```

<details>
<summary>vim-plug / native packages</summary>

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

</details>

Calling `setup()` is optional — the plugin works with its defaults as soon
as a `.bal` file is opened. Call it only to override options.

## Quick start

Open a `.bal` file. You get indentation, syntax highlighting, and the
language server attaches automatically (first start takes a few seconds
while the JVM warms up — watch `:checkhealth vim.lsp`).

Neovim's default LSP mappings work out of the box: `K` hover, `grn` rename,
`gra` code action, `grr` references, `gO` document symbols, `[d`/`]d`
diagnostics.

## Commands

| Command | Action |
| --- | --- |
| `:BallerinaFormat` | Format the file (or its enclosing package) now |
| `:BallerinaFormatToggle` | Toggle format-on-save for this buffer |
| `:BallerinaRun [args]` | `bal run` the package/script in a terminal split |
| `:BallerinaTest [args]` | `bal test` in a terminal split |
| `:BallerinaBuild [args]` | `bal build` in a terminal split |

`Run`/`Test`/`Build` accept arguments: everything before a literal `--` is
a CLI option (before the target), everything after is a program argument
(after the target) — matching `bal run [options] [target] [-- program-args]`:

```vim
:BallerinaTest --tests fooTest
:BallerinaRun -- 8080 --verbose
```

Compiler diagnostics *and* `bal test` assertion failures both land in the
quickfix list — the quickfix window opens automatically once you close the
terminal split (it won't pop up over output you're still reading). Prefer
`:make`? `:compiler ballerina` sets the same `makeprg`/`errorformat`.

Saving a file runs `bal format` in the background. To turn that off for one
buffer, use `:BallerinaFormatToggle` (or set
`vim.b.ballerina_disable_format = true`); to turn it off everywhere, set
`format_on_save = false`.

## Configuration

Defaults:

```lua
require("ballerina").setup({
  bal_cmd = nil,   -- path to the `bal` binary; nil = auto-detect
  bal_home = nil,  -- path to a distribution root; nil = auto-detect
  format_on_save = true,
  indent = true,
  lsp = {
    enabled = true,
    root_markers = { "Ballerina.toml" },
    file_watch = true,  -- see Troubleshooting if you hit a watcher crash
    config = nil,       -- extra vim.lsp.Config fields, e.g. capabilities
  },
  dap = {
    enabled = true,
  },
})
```

### Setting the Ballerina distribution

By default the plugin resolves `bal` from your `PATH`, then
`$BALLERINA_HOME/bin/bal`, then the official installer locations.
`:checkhealth ballerina` always shows which one it picked.

Override it with either:

- **`bal_home`** — a distribution root (the `$BALLERINA_HOME` layout, with
  `bin/bal` inside). Handy for pointing at a locally built distribution.
- **`bal_cmd`** — an exact binary path. Wins over `bal_home` if both are set.

**Globally**, in every project:

```lua
require("ballerina").setup({
  bal_home = "~/ballerina-lang/distribution/zip/jballerina-tools/build/"
    .. "extracted-distributions/jballerina-tools-<version>",
})
```

**Per-project** — e.g. trying a local `ballerina-lang` build against one
repo without touching your global config — pick one:

- A project-local `.nvim.lua` (Neovim's `exrc`, see `:h exrc`) that calls
  `setup()` with a different `bal_home`. Requires `vim.o.exrc = true` and
  trusting the file once (`:h :trust`).
- `$BALLERINA_HOME` set per-directory, e.g. via
  [direnv](https://direnv.net/) — already in the auto-detect chain, so it
  works automatically *as long as `bal_home`/`bal_cmd` aren't also set
  globally* (explicit config always wins over the env var).

### LSP capabilities

To pass completion capabilities from
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

Or, since the server is a native `vim.lsp.config` definition, set it
directly without going through `setup()`:

```lua
vim.lsp.config("ballerina", {
  capabilities = require("blink.cmp").get_lsp_capabilities(),
})
```

<details>
<summary>Using nvim-lspconfig?</summary>

[nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) ships an
equivalent `ballerina` definition. That's fine: Neovim merges same-named
`lsp/` definitions, and anything set via `vim.lsp.config("ballerina", ...)`
wins over both. You will not get two clients.

</details>

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

- Run `:checkhealth ballerina` first — it verifies the Neovim version,
  locates `bal` (and prints which one), and reports the LSP client state.
- Language server not attaching? Almost always `bal` missing from the
  environment Neovim was launched in — see
  [Setting the Ballerina distribution](#setting-the-ballerina-distribution).
- `:checkhealth vim.lsp` shows the client log if the server starts and then
  crashes.

<details>
<summary>Neovim crashes with ENAMETOOLONG from vim._watch</summary>

> [!WARNING]
> Neovim can crash on macOS when LSP file-watching hits a pathologically
> long build-cache path. This plugin scopes what it watches to work around
> it, but see the workaround below if it still happens to you.

Mentioning a path under a compiler/Gradle build cache (`target/`,
`.gradle/`, ...): a known Neovim limitation on macOS, where LSP workspace
file watching uses a single recursive `fs_event` over the whole project by
default. It has no way to exclude subdirectories at the OS level, so if a
build ever produces a pathologically long or invalid path there (observed
with JaCoCo code-coverage instrumentation in Gradle-wrapped builds), Neovim
asserts and crashes outright — before the change even reaches this
plugin's LSP client.

This plugin works around it by scoping what gets watched to Ballerina's
own package structure (`Ballerina.toml`, loose `.bal` files, `modules/`,
`generated/`) instead of the whole workspace folder, so a build cache is
never watched, recursively or otherwise — see `lua/ballerina/lsp_watch.lua`
and `docs/proposals/scoped-lsp-file-watch.md` for the mechanism.

Even the package root's own non-recursive watch isn't fully immune: under a
heavy write burst inside a build-cache directory (JaCoCo instrumenting
hundreds of classes during `bal test --code-coverage` is the observed
trigger), a stray event can still surface a pathologically long path from
deep inside `target/`, and core's `vim._watch.watch` asserts and crashes on
that unconditionally. This plugin's root watcher uses its own fs_event
wrapper instead of calling into core's, so that specific assert can no
longer bring Neovim down.

If you hit a crash anyway (e.g. a Ballerina LS version that registers watch
patterns this plugin doesn't recognize — it warns loudly when that
happens), set `lsp.file_watch = false` as a full opt-out. The tradeoff:
the server no longer auto-discovers files it didn't get through Neovim
(git checkouts/pulls, `.bal` source generated by `bal openapi`/`grpc`/etc.
run outside Neovim) — open or re-save the generated file, or `:LspRestart`,
to pick those up.

</details>

## Grammar notes

<details>
<summary>Why not the official TextMate grammar?</summary>

The official grammar (`ballerina.YAML-tmLanguage`) is a **TextMate**
grammar consumed by the VS Code extension, forked from the same scaffold
used for TypeScript's grammar. Most of its complexity is generic
disambiguation machinery (arrow functions vs. comparisons vs. generics)
that doesn't reflect anything Ballerina-specific and can't be expressed in
Vim's regex engine (no recursive patterns). Rather than attempt a
byte-for-byte port, this plugin takes the authoritative keyword/type lists
from the compiler's `LexerTerminals.java` (plus parser-level contextual
keywords like `group` and `collect`) and implements conventional
`:syntax keyword`/`:syntax match`/`:syntax region` rules around them — the
same level of coverage most language syntax files have.

</details>

## Roadmap

- [neotest](https://github.com/nvim-neotest/neotest) adapter for `bal test`
- Snippets
- Treesitter support, if/when a Ballerina grammar appears

## Related

- [blink.cmp](https://github.com/Saghen/blink.cmp) / [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) — completion sources, see [LSP capabilities](#lsp-capabilities)
- [neotest](https://github.com/nvim-neotest/neotest) — test runner UI; a `bal test` adapter is planned, see [Roadmap](#roadmap)
- [nvim-dap](https://github.com/mfussenegger/nvim-dap) — debugging front-end, see [Debugging](#debugging)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). In short: `make test`, `make lint`,
`make fmt` — CI runs the same checks.

## License

[MIT](LICENSE)

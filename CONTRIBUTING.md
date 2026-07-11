# Contributing to ballerina.nvim

Thanks for helping out! The workflow is small on purpose.

## Development setup

- Neovim >= 0.11
- [stylua](https://github.com/JohnnyMorganz/StyLua) for formatting
- [luacheck](https://github.com/lunarmodules/luacheck) for linting
- The [Ballerina](https://ballerina.io/downloads/) distribution, if you want
  to exercise the LSP/format paths manually

To try your working copy against a real file:

```sh
nvim --clean --cmd "set rtp+=$(pwd)" some/project/main.bal
```

## Checks

CI runs exactly these; run them locally before opening a PR:

```sh
make test       # zero-dependency suite, runs via `nvim -l tests/run.lua`
make lint       # luacheck
make fmt-check  # stylua --check   (make fmt to fix)
```

Tests live in `tests/run.lua` — plain functions, no framework. Add a case to
the relevant table (the indent tests are table-driven) or a new `test(...)`
block.

## Releasing (maintainers)

Releases are cut from the Actions tab: **Release → Run workflow**. The
workflow reads the `VERSION` file (e.g. `0.2.0-dev`), releases the stripped
version (`0.2.0`): it commits, tags `v0.2.0`, creates the GitHub Release
with generated notes, publishes to LuaRocks, and finally bumps `VERSION`
to the next `-dev` version (patch by default; minor/major selectable in the
run form). An explicit version can be supplied to override the file.

Requires the `LUAROCKS_API_KEY` repository secret. The workflow is
re-run-safe: the tag/release steps skip themselves if they already exist.

## Conventions

- Match the existing code style (stylua enforces layout; keep comments to
  constraints the code can't express).
- Keyword/type lists in `syntax/ballerina.vim` follow the compiler's
  `LexerTerminals.java` — cite it when changing them.
- One logical change per PR.

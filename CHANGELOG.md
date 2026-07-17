# Changelog

All notable changes to this project are documented in this file. The format
is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.2] - 2026-07-17

### Fixed

- Closed a race in the 0.2.1 fix above: `bal format` can take a second or
  more (JVM startup), and it rewrites the file on disk well before its
  completion callback runs. Saving again inside that window used to hit
  Neovim's stale-timestamp check via a plain, unrelated `:w` before the
  plugin's own callback had a chance to resync — same false "file has been
  changed since reading it" warning, just from a different code path. A
  `BufWritePre` guard now pre-empts it whenever a `bal format` this plugin
  started is still in flight for the buffer being saved.

## [0.2.1] - 2026-07-17

### Fixed

- Format-on-save no longer leaves Neovim's file-timestamp bookkeeping
  stale after `bal format` rewrites a buffer's file on disk, which used to
  make the *next* save falsely warn `WARNING: The file has been changed
  since reading it!!!` for a change the plugin itself made.

## [0.2.0] - 2026-07-13

### Added

- `lsp.file_watch` option (`true` by default) to opt out of LSP workspace
  file watching. Neovim's recursive watcher has been observed to crash
  outright on macOS when a compiler/Gradle build cache (`target/`,
  `.gradle/`, ...) contains a pathologically long or invalid path (seen
  with JaCoCo code-coverage instrumentation in Gradle-wrapped builds); this
  gives an escape hatch since the client can't exclude subdirectories from
  the watch. See README Troubleshooting.
- File watching is now scoped to Ballerina's package structure
  (`Ballerina.toml`, loose `.bal` files, `modules/`, `generated/`) instead
  of a single recursive watch over the whole workspace, so a build cache
  is never watched in the first place — fixing the `ENAMETOOLONG` crash
  above for `lsp.file_watch = true` (the default) rather than only working
  around it by turning watching off. `lsp.file_watch = false` remains
  available as a full opt-out for whatever this scoping doesn't cover. See
  `docs/proposals/scoped-lsp-file-watch.md`.

### Fixed

- Run/test/build terminal split now starts in terminal-job mode
  (`vim.cmd.startinsert()` after `jobstart`), so `<C-c>` reaches the
  process immediately instead of being interpreted as a Neovim
  normal-mode command — e.g. to stop a long-running `bal run` service.
  ([#1](https://github.com/redpierrot/ballerina.nvim/issues/1))

## [0.1.0] - 2026-07-11

### Added

- Syntax highlighting built from the Ballerina compiler's keyword lists
  (`LexerTerminals.java`), including contextual query keywords and the `re`
  regexp template prefix.
- Native LSP setup (`lsp/ballerina.lua` + `vim.lsp.enable`), with a
  `lsp.config` option for `capabilities`/`settings` passthrough.
- Package-aware format-on-save: formats the enclosing package and reloads
  every affected, unmodified buffer.
- Brace/paren-aware `indentexpr` (Ballerina-aware comment/string/template
  stripping, quoted-identifier safe).
- Buffer-local commands: `:BallerinaFormat`, `:BallerinaFormatToggle`,
  `:BallerinaRun`, `:BallerinaTest`, `:BallerinaBuild` — the last three
  with argument passthrough (`:BallerinaRun -- 8080`,
  `:BallerinaTest --tests fooTest`).
- Debugging via nvim-dap: the Ballerina debug adapter
  (`bal start-debugger-adapter`) and launch/attach configurations are
  registered automatically when nvim-dap is installed.
- Quickfix integration: diagnostics from run/test/build output are parsed
  (with full ranges) into the quickfix list, plus a `:compiler ballerina`
  definition for `:make`.
- `:checkhealth ballerina`.
- `bal` auto-detection: PATH, then `$BALLERINA_HOME/bin/bal`, then the
  official Linux/macOS/Windows install locations, with a friendly one-shot
  warning when missing.

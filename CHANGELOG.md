# Changelog

All notable changes to this project are documented in this file. The format
is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
  `:BallerinaRun`, `:BallerinaTest`, `:BallerinaBuild`.
- `:checkhealth ballerina`.
- `bal` auto-detection across the official Linux/macOS/Windows install
  locations, with a friendly one-shot warning when missing.

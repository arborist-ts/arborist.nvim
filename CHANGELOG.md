# Changelog

All notable changes to this project will be documented in this file.

## 0.2.1 — 2026-04-09

- Fix tree-sitter indentation: `vim.treesitter.indentexpr()` does not exist in
  Neovim, so `indentexpr` was silently a no-op (new lines always started at
  column 0). Added `lua/arborist/indent.lua` which evaluates `indents.scm`
  queries directly. ([#2](https://github.com/arborist-ts/arborist.nvim/issues/2))
  Thanks to [@mike-lloyd03](https://github.com/mike-lloyd03) for reporting,
  [@9seconds](https://github.com/9seconds) for pinpointing the root cause,
  and [@daliusd](https://github.com/daliusd) for helping diagnose the issue.

## 0.2.0 — 2026-04-07

- Enhanced queries: community-curated highlights, folds, indents, and injections
  from [arborist-ts/queries](https://github.com/arborist-ts/queries), overlaid
  automatically on top of parser-repo queries (329 languages)
- Queries applied to built-in parsers (e.g. lua, vim, markdown) on FileType
- New config option: `queries_url` for custom queries repo
- ArboristClean now wipes all query files (not just lock-file entries)

## 0.1.0 — 2026-04-06

Initial release.

- WASM-first install chain: CDN download → tree-sitter build --wasm → native .so
- Auto-detect and install parsers on FileType events
- Registry-driven parser resolution (326 parsers)
- Neovim filetype mappings and ignore list from registry
- Convention-based fallback for parsers not in the registry
- Daily auto-update with per-parser git diff
- Commands: `:Arborist`, `:ArboristInstall`, `:ArboristUpdate`, `:ArboristClean`
- WASM support detection at startup (instant, no trial-and-error)
- Zero-config via `plugin/arborist.lua`

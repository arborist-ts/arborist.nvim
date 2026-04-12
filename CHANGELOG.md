# Changelog

All notable changes to this project will be documented in this file.

## 0.4.0 — 2026-04-12

### Breaking
- `setup()` is now required. Auto-setup from `plugin/arborist.lua` has been
  removed, along with the `vim.g.arborist_loaded` escape hatch. Add
  `require("arborist").setup()` (with or without options) to your config.

## 0.3.0 — 2026-04-11

### Added
- Bundled registry (327 parsers) and queries (330 languages) ship with the
  plugin — no runtime fetching needed. Data is sourced from
  [arborist-ts/registry](https://github.com/arborist-ts/registry) and
  [arborist-ts/queries](https://github.com/arborist-ts/queries)
- New `install_popular` option (default: `true`): eagerly installs parsers
  for common languages at startup
- New `ensure_installed` option: additional parsers to install at startup
- Custom tree-sitter query predicates for better indent support
- Health check via `:checkhealth arborist`
- Neovim help file (`:help arborist`)

### Changed
- Install chain now builds from source instead of downloading from CDN —
  eliminates incompatible WASM format issues and orphaned parser files
- Batch installs group parsers by repo URL: each repo clones once, parsers
  sharing a repo (e.g. typescript + tsx) build sequentially, different repos
  clone in parallel
- WASM support detected lazily on first install instead of at startup
- Built WASM parsers are verified at load time with automatic native fallback
- Build/clone errors now include command stderr for diagnostics

### Fixed
- WASM CDN parser format (dylink section) incompatible with Neovim's
  wasmtime, causing crashes on startup ([#3](https://github.com/arborist-ts/arborist.nvim/issues/3))
- Race condition: concurrent mono-repo clones (e.g. typescript + tsx) could
  return incomplete clone paths
- `vim.treesitter.language.add()` can throw on broken parser files, crashing
  setup — all calls now wrapped in pcall
- Incomplete clones and missing source directories now handled gracefully

### Removed
- WASM CDN download path (`wasm_url` config option, `curl` dependency)
- `registry_url` and `queries_url` config options (data is bundled)

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

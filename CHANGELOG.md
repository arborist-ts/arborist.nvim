# Changelog

All notable changes to this project will be documented in this file.

## 0.7.0 — 2026-05-04

Robustness release. The startup install pipeline gains cross-instance dedup
via PID lock files, a serialized WASM-build path that defeats the wasi-sdk
download stampede, and automatic resolution of parser dependencies declared
in the registry. Per-parser install progress is surfaced live during both
the popular-set batch and on-demand single-parser installs. Two new
configuration options (`concurrency`, `disable`) round out the release.

Thanks to @frantisekstanko for deep diagnoses on #9, #10, #11, #12 and the
three PRs (#13, #14, #15) that ship most of this release; to @LordMZTE for
#16; to @pianocomposer321 and @jototland for #8; to @psy-q for #9; and to
@Kreeblah for #7.

### Added
- **Auto-install of parser `requires` dependencies** (#10, #14). The
  `requires` field in `parsers.toml` (e.g. `php` requires `php_only`,
  `angular` requires `html` + `html_tags`) is now expanded transitively
  before grouping by repo URL. Topologically ordered so deps build before
  their dependents.
- **`concurrency` config option** (#12, #13). Caps how many repos
  clone/build in parallel during a batch install. Default `nil` (unlimited)
  preserves existing behavior; `concurrency = 4` is a reasonable cap on
  metered connections, `concurrency = 1` for fully sequential.
- **`disable` config option** (#8). Per-language opt-out for tree-sitter
  features. `disable.highlight` skips `vim.treesitter.start()`;
  `disable.indent` skips the `indentexpr` setup. Useful for filetypes
  where tree-sitter highlighting/indent misbehaves (e.g. csv, markdown).
- **Per-parser install progress** (#11, #15). The startup batch now
  reports `[N/M] lang` notifications as each parser settles, opens with
  `Installing N parsers...`, and ends with a `Failed: ...` summary if
  anything broke. On-demand FileType installs emit
  `Installing <lang>...` followed by `<lang> installed` or
  `<lang> install failed: ...`.
- **`compiler` accepts an argv list** (#16). `config.compiler` now takes
  either a string or a list, fixing wrapper-style invocations like
  `compiler = { "zig", "cc" }`. Bare strings continue to work.
- **Vimdoc coverage for `concurrency`, `disable`, and `compiler`'s argv
  shape.** `:help arborist-options` no longer trails the README.
- **`ghostty` parser entry and bundled queries** (synced from
  arborist-ts/registry and arborist-ts/queries). Ghostty configuration
  and theme files. Maintainer: @bezhermoso.

### Fixed
- **`tree-sitter build --wasm` no longer stampedes the wasi-sdk
  download** (#9). On a fresh install with `prefer_wasm = true` and
  `install_popular = true`, ~29 parallel WASM builds each kicked off
  their own `curl` of the ~80 MB WASI SDK tarball, freezing small VMs.
  WASM builds are now serialized through a single-slot mutex; the first
  downloads the SDK, the rest reuse the cached copy. Native builds
  remain parallel.
- **Duplicate `git clone` / `git fetch` storms eliminated** (#12, #13).
  Concurrent `FileType` / `BufReadPost` events for the same uninstalled
  lang each used to spawn an independent install, multiplied by buffer
  count. A new lock-file scheme under the repo cache claims each lang
  atomically (`O_CREAT|O_EXCL`), then swaps the held PID to the running
  git child so the lock survives Vim mid-install exits — a restarted
  Neovim correctly defers to the orphan git process and only reclaims
  the lock once it exits. Stale-PID cleanup prevents permanent blocks
  after a real failure.
- **In-progress lock cleared on clone failure.** Follow-up to #13: a
  transient `git clone` error left the lock pointing at the still-alive
  Neovim PID, so subsequent retries within the same session were
  falsely deferred. Build-stage failures were already cleaning up; only
  the clone-stage path needed the fix.
- **Plaintext files no longer attempt parser install** (#7).

## 0.6.0 — 2026-04-13

Architecture release. Parser pins separate from editor-neutral metadata.
arborist-ts/registry becomes a clean facts-only database that any tool can
consume; nvim-specific revision decisions move into arborist.nvim itself.
Bundled data refreshed from nvim-treesitter `main` snapshot (the original
project was archived 2026-04-03; main is its frozen final state).

### Added
- **`registry/pins.toml`** — nvim-specific parser revision pins, separated
  from the editor-neutral `registry/parsers.toml`. Each pin selects a SHA
  whose grammar is compatible with arborist's bundled queries and the
  current tree-sitter ABI. Entries marked `override = true` survive
  `scripts/sync-pins.lua` runs.
- **`scripts/sync-pins.lua`** — maintainer tooling. Reads nvim-treesitter
  main's `lua/nvim-treesitter/parsers.lua`, extracts revisions, merges
  with local overrides. Idempotent. Reports added/updated/unchanged/
  override-preserved counts.
- **Bundled `registry/parsers.toml` now ships richer metadata** — beyond
  `url` and `location`, captures `maintainers` (GitHub handles), `requires`
  (parser dependencies), `readme_note` (human-readable gotchas), `branch`
  (non-default git branch, rare), and `generate` (whether the grammar
  needs `tree-sitter generate` before build). All editor-neutral facts.
  arborist's runtime reads what it consumes (`url`, `location`, `revision`
  via `pins.toml`) and treats the rest as data-product metadata for
  contributors and human consumers.

### Changed
- **Bundled parser registry refreshed from nvim-treesitter `main`
  snapshot.** master/lockfile.json is no longer the source. ~14 newly-pinned
  arborist-only parsers added; some pins shifted to align with main's
  versions.
- **Python pin held at `710796b8…`** (`override = true`) — main pins
  v0.25.0 but the bundled `python/indents.scm` has the broken
  `(ERROR (block (expression_statement (identifier) @_except)
  @indent.branch))` pattern that doesn't compile against v0.25. The
  override preserves query compatibility.
- **`registry.lua` TOML reader** extended to handle string arrays
  (`maintainers`, `requires`) and booleans (`generate`). `resolve(lang)`
  merges descriptive fields from `parsers.toml` with the revision from
  `pins.toml`.

### Removed
- **`scripts/sync-upstream-revisions.lua`** (242 lines) — superseded by
  `scripts/sync-pins.lua` (nvim-specific) plus the editor-neutral
  `arborist-ts/registry/scripts/sync.lua` (descriptive fields only). The
  master/lockfile.json source no longer exists upstream.

### Notes
- nvim-treesitter is archived. Bundled data is the April 2026 frozen
  snapshot. A community fork at `neovim-treesitter/nvim-treesitter` exists
  but isn't yet mature enough to track (single-maintainer, broken CI,
  distributed-query model). Revisit in ~90 days.
- main dropped two filetype mappings during its rewrite: `bash → ["sh"]`
  (was `["sh", "zsh"]`) and `latex → ["tex"]` (was `["plaintex", "tex"]`).
  arborist's `latex = ["plaintex", "tex"]` is restored locally so
  `.plaintex` files still get the latex parser. The `bash → zsh` mapping
  is intentionally NOT restored because arborist ships its own dedicated
  `[zsh]` parser. The registry's sync script now preserves manual
  filetype mappings across runs.

## 0.5.0 — 2026-04-13

Resilience release. Arborist now survives malformed queries, parser-version
drift, and never runs on buffers it has no business touching. Every shipped
parser is pinned to a community-vetted revision so bundled queries always
compile against the grammar they were written for.

### Added
- **Parser revision pinning.** `registry/parsers.toml` now accepts an
  optional `revision` field (commit SHA or tag) per entry. The installer
  does a full clone and `git checkout --detach` when a pin is set, so the
  built parser matches the grammar the bundled query was authored against.
  Unpinned entries keep the prior shallow-clone-at-HEAD behavior.
- **`scripts/sync-upstream-revisions.lua`** — idempotent sync script that
  reads nvim-treesitter's `lockfile.json` (local or via `curl`) and injects
  `revision = "<sha>"` into `registry/parsers.toml` for every matching
  language. Prints a summary report with additions, updates, arborist-only
  and lockfile-only languages. Re-run whenever the upstream lockfile moves.
- **`lua/arborist/query_safe.lua`** — defensive wrappers around
  `vim.treesitter.query.get` and `query:iter_captures`. Branches on
  nil-return (silent — parser still loading) vs throw (notify once per
  `(lang, qtype, err)` then degrade gracefully). `reset()` / `reset_all()`
  invalidate the dedup memory after a fix.

### Fixed
- **Malformed queries no longer cascade-crash.** Any `.scm` that fails
  tree-sitter's static validator used to throw straight out of arborist's
  FileType autocmd into whatever triggered the event — including
  nvim-dap's integrated-terminal buffer setup, breaking Python debugger
  launches. Five previously-unguarded call sites are now routed through
  `query_safe`; a broken query emits one notify and falls back to
  Neovim's default indent.
- **Python indent query incompatibility.** Tree-sitter-python 0.25
  (HEAD) changed ERROR-node child semantics, invalidating a
  community-inherited pattern (`(ERROR (block (expression_statement
  (identifier) @_except) @indent.branch))`) that compiles cleanly against
  the nvim-treesitter-pinned `710796b8`. Ships with 319 revision pins so
  the bundled queries match the grammar versions they were tested on.
- **Arborist no longer touches special buffers.** FileType / BufReadPost
  autocmds and `enable()` early-return when `buftype ~= ""`, skipping DAP
  REPL (`terminal`), dapui panes (`nofile`), DAP prompt inputs
  (`prompt`), quickfix, help, and other special buffers that carry
  filetypes but shouldn't drive parser install or indent setup.
- **`:ArboristUpdate` no longer clobbers pinned parsers.** Revision-pinned
  entries are skipped during the cadence-based update pass so
  `git reset --hard FETCH_HEAD` can't silently move a parser off its pin.
  Bump a pin via `scripts/sync-upstream-revisions.lua` and re-install.

### Changed
- **Bundled registry pins 319 parsers** — 312 synced from
  nvim-treesitter's `lockfile.json` plus 7 manual additions for languages
  upstream ships under different names (`blueprint`, `fusion`, `ipkg`,
  `jsonc`, `norg` as new entries; `robots_txt` and `systemverilog` absorb
  upstream pins for same-repo aliases `robots` and `verilog`). 15
  arborist-only languages remain unpinned and will continue tracking
  their repo HEAD — the runtime `query_safe` net catches any query that
  drifts out of compatibility.
- **`arborist.ParserInfo`** gains an optional `revision?: string` field
  alongside `url`, `location`, and `fallback_url`.

## 0.4.1 — 2026-04-12

### Fixed
- `No handler for is-not?` errors when opening files (ruby, javascript, etc.)
  whose queries use the `#is?` / `#is-not?` predicates. The previous
  registration was a no-op directive; the predicates are now backed by a real
  locals-scope lookup that mirrors nvim-treesitter's semantics, so highlights
  guarded by `#is-not? local` resolve correctly instead of erroring or
  mis-applying.

### Changed
- `setup()` now prepends the plugin's own directory to `runtimepath` so
  arborist's curated bundled queries take precedence over stale query files
  left behind in `~/.local/share/nvim/site/queries/` by prior tree-sitter
  plugin installs.

### Added
- `lua/arborist/locals.lua`: minimal per-buffer locals-scope lookup
  (`find_definition_kind`) used by the new `#is?` / `#is-not?` predicates.
  Cached by `changedtick`.

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

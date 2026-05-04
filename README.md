# arborist.nvim

WASM-first tree-sitter parser manager for Neovim 0.12+. Parsers install
automatically when you open files. No manual steps, no maintenance.

## Install

```lua
vim.pack.add({
  "https://github.com/arborist-ts/arborist.nvim",
})
require("arborist").setup()
```

Call `setup()` in your config — with or without options. To customize:

```lua
require("arborist").setup({
  update_cadence = "weekly",
  overrides = {
    my_language = { url = "https://github.com/me/tree-sitter-my-language" },
  },
})
```

All options and their defaults:

| Option             | Default                           | Description                                                |
| ------------------ | --------------------------------- | ---------------------------------------------------------- |
| `prefer_wasm`      | `true`                            | Try WASM before native compilation                         |
| `update_cadence`   | `"daily"`                         | `"daily"`, `"weekly"`, or `"manual"`                       |
| `compiler`         | `"cc"`                            | C compiler for native .so builds (string or argv list)     |
| `install_popular`  | `true`                            | Install popular language parsers at startup                |
| `ensure_installed` | `{}`                              | Additional parsers to install eagerly at startup           |
| `ignore`           | `{}`                              | Extra filetypes to skip (merged with registry defaults)    |
| `overrides`        | `{}`                              | Extra parsers not in the registry                          |
| `concurrency`      | `nil`                             | Max repos to clone/build in parallel (`nil` = unlimited)   |
| `disable`          | `{ highlight = {}, indent = {} }` | Per-lang opt-out for tree-sitter highlight or indent       |

`disable` example — turn off TS indent for markdown and TS highlight for csv:

```lua
require("arborist").setup({
  disable = {
    indent = { "markdown" },
    highlight = { "csv" },
  },
})
```

## Parsers and Queries

Arborist takes a two-pronged approach so everything works out of the box:

**Queries for 330 languages** are bundled with arborist.nvim, providing
syntax highlighting, folds, indents, and injections for every language
Neovim supports — no parser needed yet.

**Parsers for common languages** are installed eagerly at startup when
`install_popular` is enabled (the default). This covers the most popular
programming languages, common config/data formats (JSON, YAML, TOML, XML,
INI, Dockerfile, Makefile), and parsers needed by popular plugins like
[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)
(markdown, markdown_inline, html, latex). Set `install_popular = false`
to disable. Use `ensure_installed` to add parsers beyond the popular set.

**Everything else** installs on demand — open a file and arborist handles
the rest.

## How It Works

1. You open a file
2. Arborist checks if a parser exists for that filetype
3. If not, it clones the source and builds one:
   - `tree-sitter build --wasm` (sandboxed, preferred)
   - `tree-sitter build` (native .so)
   - `cc` compilation (fallback)
4. Highlighting and indentation activate immediately

WASM builds are verified at load time — if the parser fails to load,
arborist falls through to native compilation automatically. WASM is
skipped entirely if your Neovim build lacks wasmtime.

Parser locations are resolved from a bundled
[community registry](https://github.com/arborist-ts/registry) of 327
parsers. Unknown parsers fall back to convention-based lookup in the
`tree-sitter-grammars` and `tree-sitter` GitHub orgs.

Batch installs group parsers by repository — parsers sharing a repo
(e.g. typescript + tsx) clone once and build sequentially, while
different repos clone in parallel.

User queries in `~/.config/nvim/queries/` always take highest priority.

## Data Sources

Arborist bundles data from two companion repos so it works offline and
ships cohesive versions:

| Data                          | Source                                                          | Bundled in  |
| ----------------------------- | --------------------------------------------------------------- | ----------- |
| Parser registry (327 parsers) | [arborist-ts/registry](https://github.com/arborist-ts/registry) | `registry/` |
| Query files (330 languages)   | [arborist-ts/queries](https://github.com/arborist-ts/queries)   | `queries/`  |

Changes flow **upstream first**: updates are made in the source repos,
then synced into arborist.nvim before each release via
`scripts/sync-upstream.sh`. This keeps the upstream repos canonical and
arborist.nvim releases self-contained.

## Commands

| Command                   | Description                           |
| ------------------------- | ------------------------------------- |
| `:Arborist`               | Show installed parsers and status     |
| `:ArboristInstall {lang}` | Install a parser manually             |
| `:ArboristUpdate`         | Check all parsers for updates         |
| `:ArboristClean`          | Remove all arborist-managed parsers   |
| `:checkhealth arborist`   | Verify setup, tools, and bundled data |

## Requirements

- Neovim 0.12+
- `git`
- `tree-sitter` CLI (for building from source)
- A C compiler (fallback when `tree-sitter` CLI is unavailable)
- For WASM: Neovim built with `ENABLE_WASMTIME=ON`

## License

[MIT](LICENSE)

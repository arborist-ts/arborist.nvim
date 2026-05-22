--- Configuration defaults and merge.

--- @class arborist.DisableConfig
--- @field highlight? string[] Langs to skip vim.treesitter.start on (no TS highlighting)
--- @field indent? string[] Langs to skip indentexpr setup on (uses Vim default)
--- @field fold? string[] Langs to skip foldexpr setup on (uses Vim default folding)

--- @class arborist.Config
--- @field prefer_wasm boolean Try WASM before native compilation
--- @field wasm_build_timeout integer Milliseconds before a WASM build is aborted
--- @field update_cadence "daily"|"weekly"|"manual" Auto-update frequency
--- @field compiler string|string[] C compiler for native .so builds (string or argv list, e.g. {"zig","cc"})
--- @field install_popular boolean Install popular language parsers at startup
--- @field ensure_installed "all"|string[] Parsers to install eagerly at startup. A list of parser names, or the string "all" to install every parser in the registry.
--- @field ignore string[] Extra filetypes to ignore (merged with registry defaults)
--- @field overrides table<string, {url: string, location?: string}> Extra parser overrides
--- @field concurrency integer? Max parallel repo installs (nil = unlimited)
--- @field fold boolean Tree-sitter folding — unset: cautious auto, true: assertive, false: off
--- @field disable arborist.DisableConfig Per-feature, per-lang opt-out

--- @type arborist.Config
local defaults = {
  prefer_wasm = true,
  -- Milliseconds before a `tree-sitter build --wasm` is aborted. The first
  -- WASM build lazily downloads ~80 MB of wasi-sdk; if that stalls, the build
  -- would otherwise hang forever and (because WASM builds are serialized) take
  -- the whole batch install down with it. On a timeout arborist gives up on
  -- WASM and compiles natively instead.
  wasm_build_timeout = 300000,
  update_cadence = "daily",
  compiler = vim.env.CC or "cc",
  -- Install popular parsers at startup. Covers the most popular programming
  -- languages, common config formats, and parsers needed by popular plugins
  -- like render-markdown.nvim. Set to false to disable.
  install_popular = true,
  -- Additional parsers to install eagerly at startup (beyond the popular set).
  -- A list of parser names, or the string "all" to install every parser in
  -- the registry.
  ensure_installed = {},
  ignore = {},
  overrides = {},
  -- Maximum number of repos to clone/build in parallel. nil means unlimited.
  -- Set to 1 to install one at a time (useful on metered connections).
  concurrency = nil,
  -- Tree-sitter folding. Left unset, arborist enables folding (foldmethod=expr
  -- + foldexpr) for buffers whose language has a bundled `folds` query, but
  -- only on a window still at the factory foldmethod=manual, and it stays out
  -- when nvim-ufo is loaded. It raises that window's foldlevel once so the
  -- file opens expanded — never collapsed. Set fold=true to fold assertively
  -- even alongside nvim-ufo; set fold=false to disable. arborist sets
  -- foldlevel once per window but never touches foldenable. Per-lang opt-out
  -- via disable.fold.
  fold = true,
  -- Per-lang opt-out for tree-sitter features. Useful when a parser's
  -- highlights/indents/folds misbehave for a given filetype (e.g. markdown
  -- indent, csv highlighting on huge files). Buffer-local overrides remain
  -- available via after/ftplugin/<ft>.lua.
  disable = { highlight = {}, indent = {}, fold = {} },
}

local valid_cadence = { daily = true, weekly = true, manual = true }

local M = {}

--- @type arborist.Config
M.values = vim.deepcopy(defaults)

--- Whether the user explicitly passed `fold` to setup(). Distinguishes the
--- cautious-auto default (unset) from an explicit `fold = true` (assertive).
M.fold_explicit = false

--- Merge user options into config. Validates values.
--- @param opts? table
function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  M.fold_explicit = opts ~= nil and opts.fold ~= nil
  assert(valid_cadence[M.values.update_cadence],
    "[arborist] invalid update_cadence: " .. tostring(M.values.update_cadence))
end

return M

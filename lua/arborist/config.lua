--- Configuration defaults and merge.

--- @class arborist.DisableConfig
--- @field highlight? string[] Langs to skip vim.treesitter.start on (no TS highlighting)
--- @field indent? string[] Langs to skip indentexpr setup on (uses Vim default)

--- @class arborist.Config
--- @field prefer_wasm boolean Try WASM before native compilation
--- @field update_cadence "daily"|"weekly"|"manual" Auto-update frequency
--- @field compiler string|string[] C compiler for native .so builds (string or argv list, e.g. {"zig","cc"})
--- @field install_popular boolean Install popular language parsers at startup
--- @field ensure_installed string[] Additional parsers to install eagerly at startup
--- @field ignore string[] Extra filetypes to ignore (merged with registry defaults)
--- @field overrides table<string, {url: string, location?: string}> Extra parser overrides
--- @field disable arborist.DisableConfig Per-feature, per-lang opt-out

--- @type arborist.Config
local defaults = {
  prefer_wasm = true,
  update_cadence = "daily",
  compiler = vim.env.CC or "cc",
  -- Install popular parsers at startup. Covers the most popular programming
  -- languages, common config formats, and parsers needed by popular plugins
  -- like render-markdown.nvim. Set to false to disable.
  install_popular = true,
  -- Additional parsers to install eagerly at startup (beyond the popular set).
  ensure_installed = {},
  ignore = {},
  overrides = {},
  -- Per-lang opt-out for tree-sitter features. Useful when a parser's
  -- highlights/indents misbehave for a given filetype (e.g. markdown indent,
  -- csv highlighting on huge files). Buffer-local overrides remain available
  -- via after/ftplugin/<ft>.lua.
  disable = { highlight = {}, indent = {} },
}

local valid_cadence = { daily = true, weekly = true, manual = true }

local M = {}

--- @type arborist.Config
M.values = vim.deepcopy(defaults)

--- Merge user options into config. Validates values.
--- @param opts? table
function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  assert(valid_cadence[M.values.update_cadence],
    "[arborist] invalid update_cadence: " .. tostring(M.values.update_cadence))
end

return M

--- Configuration defaults and merge.

--- @class arborist.Config
--- @field prefer_wasm boolean Try WASM before native compilation
--- @field update_cadence "daily"|"weekly"|"manual" Auto-update frequency
--- @field compiler string C compiler for native .so builds
--- @field install_popular boolean Install popular language parsers at startup
--- @field ensure_installed string[] Additional parsers to install eagerly at startup
--- @field ignore string[] Extra filetypes to ignore (merged with registry defaults)
--- @field overrides table<string, {url: string, location?: string}> Extra parser overrides
--- @field concurrency integer? Max parallel repo installs (nil = unlimited)

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
  -- Maximum number of repos to clone/build in parallel. nil means unlimited.
  -- Set to 1 to install one at a time (useful on metered connections).
  concurrency = nil,
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

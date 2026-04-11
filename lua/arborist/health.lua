local M = {}

function M.check()
  vim.health.start("arborist.nvim")

  -- Neovim version
  if vim.fn.has("nvim-0.12") == 1 then
    vim.health.ok("Neovim 0.12+")
  else
    vim.health.error("Neovim 0.12+ required", { "Upgrade Neovim to 0.12 or later" })
  end

  -- WASM support
  local install = require("arborist.install")
  if install.wasm_supported == true then
    vim.health.ok("WASM support (wasmtime)")
  elseif install.wasm_supported == false then
    vim.health.warn("No WASM support", {
      "Neovim was not built with ENABLE_WASMTIME=ON",
      "Parsers will be compiled from source instead",
    })
  else
    vim.health.info("WASM support not yet tested (run setup first)")
  end

  -- External tools
  for _, tool in ipairs({ "git", "curl" }) do
    if vim.fn.executable(tool) == 1 then
      vim.health.ok(tool .. " found")
    else
      vim.health.error(tool .. " not found", { "Install " .. tool })
    end
  end

  if vim.fn.executable("tree-sitter") == 1 then
    vim.health.ok("tree-sitter CLI found")
  else
    vim.health.warn("tree-sitter CLI not found", {
      "Needed to build parsers from source (WASM or native)",
      "CDN downloads still work without it",
    })
  end

  local config = require("arborist.config")
  local compiler = config.values.compiler
  if vim.fn.executable(compiler) == 1 then
    vim.health.ok("C compiler: " .. compiler)
  else
    vim.health.warn("C compiler not found: " .. compiler, {
      "Needed as fallback for native .so builds",
      "Set the CC environment variable or configure `compiler`",
    })
  end

  -- Bundled data
  local registry = require("arborist.registry")
  if registry.load() then
    vim.health.ok("Bundled registry loaded")
  else
    vim.health.error("Failed to load bundled registry", {
      "The registry/ directory may be missing or corrupt",
      "Try reinstalling the plugin",
    })
  end

  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
  local query_dir = plugin_root .. "/queries"
  if vim.fn.isdirectory(query_dir) == 1 then
    local count = #vim.fn.glob(query_dir .. "/*/", false, true)
    vim.health.ok("Bundled queries: " .. count .. " languages")
  else
    vim.health.error("Bundled queries directory missing", {
      "The queries/ directory may be missing or corrupt",
      "Try reinstalling the plugin",
    })
  end

  -- Installed parsers
  local lock = require("arborist.lock")
  local data = lock.read()
  local count = vim.tbl_count(data.parsers)
  if count > 0 then
    vim.health.ok(count .. " parsers installed")
  else
    vim.health.info("No parsers installed yet")
  end
end

return M

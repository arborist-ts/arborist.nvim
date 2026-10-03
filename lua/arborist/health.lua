local M = {}

function M.check()
  vim.health.start("arborist.nvim")

  if vim.fn.has("nvim-0.12") == 1 then vim.health.ok("Neovim 0.12+")
  else vim.health.error("Neovim 0.12+ required", { "Upgrade Neovim to 0.12 or later" }) end

  local wasm = require("arborist.install").wasm_supported
  if wasm == true then vim.health.ok("WASM support (wasmtime)")
  elseif wasm == false then vim.health.warn("No WASM support", {
    "Neovim was not built with ENABLE_WASMTIME=ON",
    "Parsers will be compiled from source instead",
  })
  else vim.health.info("WASM support not yet tested (run setup first)") end

  -- External tools
  for _, t in ipairs({
    { "git", "error" },
    { "tree-sitter", "warn", { "Needed to build parsers from source (WASM or native)",
                                "Parsers will fall back to raw cc compilation" } },
  }) do
    if vim.fn.executable(t[1]) == 1 then vim.health.ok(t[1] .. " found")
    else vim.health[t[2]](t[1] .. " not found", t[3] or { "Install " .. t[1] }) end
  end

  local compiler = require("arborist.config").values.compiler
  if type(compiler) == "table" then compiler = compiler[1] end
  if vim.fn.executable(compiler) == 1 then vim.health.ok("C compiler: " .. compiler)
  else vim.health.warn("C compiler not found: " .. compiler, {
    "Needed as fallback for native .so builds",
    "Set the CC environment variable or configure `compiler`",
  }) end

  if require("arborist.registry").load() then vim.health.ok("Bundled registry loaded")
  else vim.health.error("Failed to load bundled registry", {
    "The registry/ directory may be missing or corrupt",
    "Try reinstalling the plugin",
  }) end

  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
  local qdir = root .. "/queries"
  if vim.fn.isdirectory(qdir) == 1 then
    vim.health.ok("Bundled queries: " .. #vim.fn.glob(qdir .. "/*/", false, true) .. " languages")
  else vim.health.error("Bundled queries directory missing", {
    "The queries/ directory may be missing or corrupt",
    "Try reinstalling the plugin",
  }) end

  local pcount = vim.tbl_count(require("arborist.lock").read().parsers)
  if pcount > 0 then vim.health.ok(pcount .. " parsers installed")
  else vim.health.info("No parsers installed yet") end
end

return M

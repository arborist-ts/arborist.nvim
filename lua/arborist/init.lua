--- arborist.nvim — WASM-first tree-sitter parser manager for Neovim 0.12+
--- Add to vim.pack and forget. Parsers auto-install when you open files.

local M = {}

--- Try to load a parser. Returns true only if the parser is available.
--- Safe wrapper: language.add can throw on broken parser files.
--- @param lang string
--- @return boolean
local function parser_loaded(lang)
  local ok, result = pcall(vim.treesitter.language.add, lang)
  return ok and result == true
end

--- Enable treesitter highlighting and indentation on a buffer.
--- @param buf integer
local function enable(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  -- Skip special buffers. DAP REPL (buftype=terminal), dap-ui panes
  -- (buftype=nofile), DAP prompt inputs (buftype=prompt), quickfix, help,
  -- etc. legitimately carry filetypes but must not drive parser install
  -- or indent setup. A live RunInTerminalRequest from nvim-dap sets a
  -- terminal-channel buffer's filetype; arborist parsing that buffer
  -- corrupts the terminal and (previously) cascaded query crashes into
  -- debugger launch failure.
  if vim.bo[buf].buftype ~= "" then return end
  pcall(vim.treesitter.start, buf)
  local lang = vim.treesitter.language.get_lang(vim.bo[buf].filetype)
  if lang then
    local q = require("arborist.query_safe").safe_get(lang, "indents")
    if q and #q.captures > 0 then
      vim.bo[buf].indentexpr = "v:lua.require'arborist.indent'.indentexpr()"
    end
  end
end

--- Configure and start arborist. Must be called for arborist to activate.
--- @param opts? table See arborist.config for available options.
function M.setup(opts)
  local config = require("arborist.config")
  local install = require("arborist.install")
  local lock = require("arborist.lock")
  local log = require("arborist.log")
  local registry = require("arborist.registry")
  local update = require("arborist.update")

  config.setup(opts)

  -- Prepend the plugin's own dir to runtimepath so its bundled, curated
  -- queries win over any stragglers users may have in site/queries (e.g.
  -- leftovers from a prior nvim-treesitter install).
  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
  vim.opt.runtimepath:prepend(plugin_root)

  -- Register custom query predicates/directives before any query loading.
  require("arborist.predicates").register()

  -- Paths
  local data = vim.fn.stdpath("data")
  local parser_dir = data .. "/site/parser"
  local query_dir = data .. "/site/queries"
  local repo_cache = vim.fn.stdpath("cache") .. "/arborist/repos"

  lock.init(data .. "/arborist-lock.json")
  install.init({ parser = parser_dir, query = query_dir, repo_cache = repo_cache })

  -- Ignore list: registry defaults + user additions
  install.set_ignore(registry.load_ignore())
  install.set_ignore(config.values.ignore)

  vim.fn.mkdir(parser_dir, "p")
  vim.fn.mkdir(query_dir, "p")
  vim.fn.mkdir(repo_cache, "p")

  registry.load()

  --- Detect lang for a buffer (uses filetype if set, otherwise matches filename).
  --- @param buf integer
  --- @return string?
  local function detect_lang(buf)
    local ft = vim.bo[buf].filetype
    if ft == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then ft = vim.filetype.match({ filename = name, buf = buf }) end
    end
    if not ft or ft == "" then return nil end
    return vim.treesitter.language.get_lang(ft)
  end

  --- Load parser and enable treesitter on all matching buffers.
  --- @param lang string
  local function enable_bufs(lang)
    parser_loaded(lang)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and detect_lang(buf) == lang then enable(buf) end
    end
  end

  local ensuring = {} --- @type table<string, boolean>

  --- Install a parser for a lang if needed, then enable on all matching buffers.
  --- @param lang string
  local function ensure_parser(lang)
    if install.should_skip(lang) then return end
    if parser_loaded(lang) then enable_bufs(lang); return end
    if ensuring[lang] then return end
    ensuring[lang] = true
    install.install(lang, function(err)
      ensuring[lang] = nil
      if err then return end
      vim.schedule(function() enable_bufs(lang) end)
    end, { silent = true })
  end

  -- Batch install: build the list, then install once registry is ready.
  local function batch_install()
    local to_install = config.values.install_popular and {
      "bash", "c", "cpp", "css", "diff", "dockerfile", "go", "html",
      "ini", "java", "javascript", "json", "latex", "lua", "make",
      "markdown", "markdown_inline", "python", "regex", "ruby", "rust",
      "toml", "tsx", "typescript", "vim", "vimdoc", "xml", "yaml",
    } or {}
    vim.list_extend(to_install, config.values.ensure_installed)

    local needed = {}
    for _, lang in ipairs(to_install) do
      if install.should_skip(lang) then -- skip
      elseif parser_loaded(lang) then enable_bufs(lang)
      elseif install.is_installing(lang) then
      else needed[#needed + 1] = lang end
    end

    if #needed == 0 then return end
    log.info("Installing parsers...")
    install.install_batch(needed, function(results)
      local failed = {}
      for lang, err in pairs(results) do
        if err then failed[#failed + 1] = lang .. " (" .. err .. ")" end
      end
      if #failed == 0 then
        log.info("Parser installation complete")
      else
        table.sort(failed)
        log.warn("Failed: " .. table.concat(failed, ", "))
      end
      vim.schedule(function()
        for _, l in ipairs(needed) do enable_bufs(l) end
      end)
    end, { silent = true })
  end

  batch_install()

  -- Auto-detect: install missing parsers on FileType
  local group = vim.api.nvim_create_augroup("arborist", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(ev)
      if vim.bo[ev.buf].buftype ~= "" then return end
      local lang = vim.treesitter.language.get_lang(ev.match)
      if lang then ensure_parser(lang) end
    end,
  })

  -- Install parsers for background buffers as they load.
  -- FileType only fires for the active buffer; BufReadPost fires for all.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      if vim.bo[ev.buf].buftype ~= "" then return end
      local lang = detect_lang(ev.buf)
      if lang then ensure_parser(lang) end
    end,
  })

  -- Commands
  vim.api.nvim_create_user_command("Arborist", function() M.status() end, {
    desc = "Show arborist status",
  })
  vim.api.nvim_create_user_command("ArboristInstall", function(c)
    install.install(c.args)
  end, {
    nargs = 1,
    desc = "Install a tree-sitter parser",
  })
  vim.api.nvim_create_user_command("ArboristUpdate", function()
    update.update_all(install.install, repo_cache)
  end, {
    desc = "Update all installed parsers",
  })
  vim.api.nvim_create_user_command("ArboristClean", function()
    local lock_data = lock.read()
    for lang in pairs(lock_data.parsers) do
      pcall(os.remove, parser_dir .. "/" .. lang .. ".so")
      pcall(os.remove, parser_dir .. "/" .. lang .. ".wasm")
    end
    vim.fn.delete(query_dir, "rf")
    vim.fn.delete(repo_cache, "rf")
    vim.fn.delete(data .. "/arborist-lock.json")
    log.info("Cleaned " .. vim.tbl_count(lock_data.parsers) .. " parsers. Restart to reinstall.")
  end, {
    desc = "Remove all arborist-managed parsers",
  })

  -- Cadence-based auto-update
  if update.due(config.values.update_cadence) then
    update.update_all(install.install, repo_cache)
  end
end

--- Print installed parser status.
function M.status()
  local data = require("arborist.lock").read()
  local wasm = require("arborist.install").wasm_supported

  local lines = {
    "arborist:",
    string.format("  WASM: %s | Cadence: %s | Last update: %s",
      wasm == true and "yes" or wasm == false and "no" or "untested",
      require("arborist.config").values.update_cadence,
      data.last_update ~= "" and data.last_update or "never"),
    "",
  }

  local langs = vim.tbl_keys(data.parsers)
  table.sort(langs)

  if #langs == 0 then
    lines[#lines + 1] = "  (no parsers installed)"
  else
    for _, lang in ipairs(langs) do
      local info = data.parsers[lang]
      lines[#lines + 1] = string.format("  %-20s %-12s %s", lang, info.mode, info.installed_at)
    end
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Install a parser programmatically.
--- @param lang string
--- @param callback? fun(err: string?)
function M.install(lang, callback)
  require("arborist.install").install(lang, callback)
end

--- Update all installed parsers.
function M.update()
  require("arborist.update").update_all(
    require("arborist.install").install, vim.fn.stdpath("cache") .. "/arborist/repos")
end

return M

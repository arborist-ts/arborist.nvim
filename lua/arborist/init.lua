--- arborist.nvim — WASM-first tree-sitter parser manager for Neovim 0.12+
--- Add to vim.pack and forget. Parsers auto-install when you open files.

local M = {}

--- Enable treesitter highlighting and indentation on a buffer.
--- @param buf integer
local function enable(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  pcall(vim.treesitter.start, buf)
  vim.bo[buf].indentexpr = "v:lua.require'arborist.indent'.indentexpr()"
end

--- Configure and start arborist. Safe to call multiple times (idempotent).
--- @param opts? table See arborist.config for available options.
function M.setup(opts)
  local config = require("arborist.config")
  local install = require("arborist.install")
  local lock = require("arborist.lock")
  local log = require("arborist.log")
  local queries = require("arborist.queries")
  local registry = require("arborist.registry")
  local update = require("arborist.update")

  config.setup(opts)

  -- Paths
  local data = vim.fn.stdpath("data")
  local cache = vim.fn.stdpath("cache")
  local parser_dir = data .. "/site/parser"
  local query_dir = data .. "/site/queries"
  local repo_cache = cache .. "/arborist/repos"
  local cache_dir = cache .. "/arborist"

  lock.init(data .. "/arborist-lock.json")
  registry.init(cache_dir)
  queries.init(cache_dir)
  install.init({ parser = parser_dir, query = query_dir, repo_cache = repo_cache })

  -- Ignore list: registry defaults + user additions
  install.set_ignore(registry.load_ignore())
  install.set_ignore(config.values.ignore)

  vim.fn.mkdir(parser_dir, "p")
  vim.fn.mkdir(query_dir, "p")
  vim.fn.mkdir(repo_cache, "p")

  registry.load()

  -- Overlay enhanced queries for all installed parsers (fast, synchronous, idempotent)
  for lang in pairs(lock.read().parsers) do
    queries.copy(lang, query_dir)
  end

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

  --- Install a parser for a lang if needed, then enable on all matching buffers.
  --- @param lang string
  local function ensure_parser(lang)
    if install.should_skip(lang) then return end
    if vim.treesitter.language.add(lang) == true then
      -- Already available — ensure enhanced queries exist, then enable
      queries.copy(lang, query_dir)
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and detect_lang(buf) == lang then
          enable(buf)
        end
      end
      return
    end
    install.install(lang, function(err)
      if err then return end
      vim.schedule(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) and detect_lang(buf) == lang then
            vim.treesitter.language.add(lang)
            enable(buf)
          end
        end
      end)
    end, { silent = true })
  end

  -- Auto-detect: install missing parsers on FileType
  local group = vim.api.nvim_create_augroup("arborist", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(ev)
      local lang = vim.treesitter.language.get_lang(ev.match)
      if lang then ensure_parser(lang) end
    end,
  })

  -- Install parsers for background buffers as they load.
  -- FileType only fires for the active buffer; BufReadPost fires for all.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
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
    queries.fetch(function()
      vim.schedule(function()
        for lang in pairs(lock.read().parsers) do
          queries.copy(lang, query_dir)
        end
      end)
    end)
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
    vim.fn.delete(cache_dir, "rf")
    vim.fn.delete(data .. "/arborist-lock.json")
    log.info("Cleaned " .. vim.tbl_count(lock_data.parsers) .. " parsers and cache. Restart to re-fetch.")
  end, {
    desc = "Remove all arborist-managed parsers and cache",
  })

  -- Registry + queries: fetch if stale
  if registry.needs_refresh() then
    registry.fetch(function()
      install.set_ignore(registry.load_ignore())
      install.set_ignore(config.values.ignore)
      -- Scan all buffers — parsers that failed heuristic resolution
      -- may now succeed with the freshly loaded registry
      vim.schedule(function()
        local seen = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) then
            local lang = detect_lang(buf)
            if lang and not seen[lang] then
              seen[lang] = true
              ensure_parser(lang)
            end
          end
        end
      end)
    end)
  end
  if queries.needs_refresh() then
    queries.fetch(function()
      -- Overlay enhanced queries for all already-installed parsers
      vim.schedule(function()
        for lang in pairs(lock.read().parsers) do
          queries.copy(lang, query_dir)
        end
      end)
    end)
  end

  -- Cadence-based auto-update
  if update.due(config.values.update_cadence) then
    update.update_all(install.install, repo_cache)
  end
end

--- Print installed parser status.
function M.status()
  local config = require("arborist.config")
  local install = require("arborist.install")
  local l = require("arborist.lock")

  local data = l.read()
  local wasm = install.wasm_supported

  local lines = {
    "arborist:",
    string.format("  WASM: %s | Cadence: %s | Last update: %s",
      wasm == true and "yes" or wasm == false and "no" or "untested",
      config.values.update_cadence,
      data.last_update ~= "" and data.last_update or "never"),
    "",
  }

  local langs = {}
  for lang in pairs(data.parsers) do langs[#langs + 1] = lang end
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
  local update = require("arborist.update")
  local install = require("arborist.install")
  update.update_all(install.install, vim.fn.stdpath("cache") .. "/arborist/repos")
end

return M

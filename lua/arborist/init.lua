--- arborist.nvim — WASM-first tree-sitter parser manager for Neovim 0.12+
--- Add to vim.pack and forget. Parsers auto-install when you open files.

local M = {}

--- Enable treesitter highlighting and indentation on a buffer.
--- @param buf integer
local function enable(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  pcall(vim.treesitter.start, buf)
  vim.bo[buf].indentexpr = "v:lua.vim.treesitter.indentexpr()"
end

--- Configure and start arborist. Safe to call multiple times (idempotent).
--- @param opts? table See arborist.config for available options.
function M.setup(opts)
  local config = require("arborist.config")
  local install = require("arborist.install")
  local lock = require("arborist.lock")
  local log = require("arborist.log")
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
  install.init({ parser = parser_dir, query = query_dir, repo_cache = repo_cache })

  -- Ignore list: registry defaults + user additions
  install.set_ignore(registry.load_ignore())
  install.set_ignore(config.values.ignore)

  vim.fn.mkdir(parser_dir, "p")
  vim.fn.mkdir(query_dir, "p")
  vim.fn.mkdir(repo_cache, "p")

  -- Registry readiness gate: on first boot (empty cache), the autocmd
  -- does nothing until the registry fetch completes. This prevents
  -- noise from UI filetypes that aren't in the ignore list yet.
  local registry_ready = registry.load()

  -- Auto-detect: install missing parsers on FileType
  local group = vim.api.nvim_create_augroup("arborist", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(ev)
      if not registry_ready then return end

      local lang = vim.treesitter.language.get_lang(ev.match)
      if not lang or install.should_skip(lang) then return end

      -- Parser already available? Just enable it.
      if vim.treesitter.language.add(lang) == true then
        enable(ev.buf)
        return
      end

      -- Not installed — async install, then enable on all matching buffers.
      -- Errors are already logged by the install module.
      install.install(lang, function(err)
        if err then return end
        vim.schedule(function()
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) then
              local ft = vim.bo[buf].filetype
              if vim.treesitter.language.get_lang(ft) == lang then
                vim.treesitter.language.add(lang)
                enable(buf)
              end
            end
          end
        end)
      end, { silent = true })
    end,
  })

  -- Eagerly scan all buffers at startup (handles `nvim file1 file2 file3`).
  -- FileType only fires for the active buffer; this ensures background buffers
  -- get their parsers installed immediately too.
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    once = true,
    callback = function()
      if not registry_ready then return end
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
          local ft = vim.bo[buf].filetype
          if ft ~= "" then
            local lang = vim.treesitter.language.get_lang(ft)
            if lang and not install.should_skip(lang) and vim.treesitter.language.add(lang) ~= true then
              install.install(lang, function(err)
                if err then return end
                vim.schedule(function()
                  -- Enable on all buffers with this filetype
                  for _, b in ipairs(vim.api.nvim_list_bufs()) do
                    if vim.api.nvim_buf_is_loaded(b) and vim.treesitter.language.get_lang(vim.bo[b].filetype) == lang then
                      vim.treesitter.language.add(lang)
                      enable(b)
                    end
                  end
                end)
              end, { silent = true })
            end
          end
        end
      end
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
      vim.fn.delete(query_dir .. "/" .. lang, "rf")
    end
    vim.fn.delete(cache_dir, "rf")
    vim.fn.delete(data .. "/arborist-lock.json")
    log.info("Cleaned " .. vim.tbl_count(lock_data.parsers) .. " parsers and cache. Restart to re-fetch.")
  end, {
    desc = "Remove all arborist-managed parsers and cache",
  })

  -- Registry: fetch if stale, then activate autocmd and retrigger
  if registry.needs_refresh() then
    registry.fetch(function()
      install.set_ignore(registry.load_ignore())
      install.set_ignore(config.values.ignore)
      registry_ready = true
      -- Retrigger FileType on all open buffers now that registry is ready
      vim.schedule(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype ~= "" then
            vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
          end
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

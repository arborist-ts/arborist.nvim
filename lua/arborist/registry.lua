--- Parser registry: fetch, cache, resolve, register filetypes.
--- All data comes from the registry repo — the plugin has zero hardcoded parser data.
---
--- Cache directory contains three files fetched from the registry repo:
---   parsers.toml    — parser name → { url, location? }
---   filetypes.toml  — parser name → [filetype aliases]  (Neovim-specific)
---   ignore.toml     — filetypes to skip                  (Neovim-specific)
---
--- TOML parsing is minimal and purpose-built for these exact formats.
--- It does NOT handle the full TOML spec (no nested tables, no multi-line values).

local config = require("arborist.config")

--- @class arborist.ParserInfo
--- @field url string Git repository URL
--- @field location? string Subdirectory within repo (for mono-repos)
--- @field fallback_url? string Secondary URL to try (set by heuristic resolve only)

local M = {}

--- @type table<string, arborist.ParserInfo>?
local entries = nil

--- @type string
local cache_dir

local fetching = false
local fetch_queue = {} --- @type fun(ok: boolean)[]  Callbacks waiting on in-flight fetch
local filetypes_registered = false

--- @param dir string
function M.init(dir) cache_dir = dir end

-- Minimal TOML readers for our exact registry format.

--- Parse parsers.toml: [section] with url = "..." and optional location = "..."
--- @param path string
--- @return table<string, arborist.ParserInfo>?
local function read_parsers(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local result = {}
  local current --- @type string?
  for line in f:lines() do
    local section = line:match("^%[([%w_]+)%]$")
    if section then
      current = section
      result[current] = {}
    elseif current then
      local key, val = line:match('^(%w+)%s*=%s*"([^"]+)"$')
      if key and val then result[current][key] = val end
    end
  end
  f:close()
  -- Drop entries without a url (comments, metadata)
  for lang, info in pairs(result) do
    if not info.url then result[lang] = nil end
  end
  return next(result) and result or nil
end

--- Parse filetypes.toml: key = ["val1", "val2"] under [filetypes] section.
--- @param path string
--- @return table<string, string[]>
local function read_filetypes(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local result = {}
  for line in f:lines() do
    local lang, arr = line:match("^([%w_]+)%s*=%s*%[(.+)%]$")
    if lang and arr then
      local fts = {}
      for ft in arr:gmatch('"([^"]+)"') do fts[#fts + 1] = ft end
      if #fts > 0 then result[lang] = fts end
    end
  end
  f:close()
  return result
end

--- Parse ignore.toml: list of quoted strings inside [ignore] section.
--- @param path string
--- @return string[]
local function read_ignore(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local result = {}
  for line in f:lines() do
    local ft = line:match('^%s*"([^"]+)"')
    if ft then result[#result + 1] = ft end
  end
  f:close()
  return result
end

--- Register filetype → parser mappings with Neovim. Idempotent.
function M.register_filetypes()
  if filetypes_registered then return end
  local ft_map = read_filetypes(cache_dir .. "/filetypes.toml")
  if not next(ft_map) then return end
  filetypes_registered = true
  for lang, fts in pairs(ft_map) do
    vim.treesitter.language.register(lang, fts)
  end
end

--- Load default ignore list from cached ignore.toml.
--- @return string[]
function M.load_ignore()
  return read_ignore(cache_dir .. "/ignore.toml")
end

--- Load cached parser registry from disk. Registers filetypes if found.
--- @return boolean loaded
function M.load()
  if entries then return true end
  entries = read_parsers(cache_dir .. "/parsers.toml")
  if entries then
    M.register_filetypes()
    return true
  end
  return false
end

--- Fetch all registry files from remote and cache them.
--- Safe to call concurrently — queues callbacks behind a single in-flight fetch.
--- @param callback? fun(ok: boolean)
function M.fetch(callback)
  if callback then fetch_queue[#fetch_queue + 1] = callback end

  if fetching then return end
  fetching = true

  local base = config.values.registry_url
  local files = {
    { url = base .. "/parsers.toml", dest = cache_dir .. "/parsers.toml" },
    { url = base .. "/neovim-filetypes.toml", dest = cache_dir .. "/filetypes.toml" },
    { url = base .. "/neovim-ignore.toml", dest = cache_dir .. "/ignore.toml" },
  }
  local remaining = #files
  local all_ok = true

  local function finish_fetch()
    remaining = remaining - 1
    if remaining > 0 then return end
    fetching = false

    if all_ok then
      local parsed = read_parsers(cache_dir .. "/parsers.toml")
      if parsed then
        entries = parsed
        filetypes_registered = false
        vim.schedule(M.register_filetypes)
      end
    end

    local cbs = fetch_queue
    fetch_queue = {}
    for _, cb in ipairs(cbs) do cb(all_ok) end
  end

  vim.uv.fs_mkdir(cache_dir, 493) -- 0755, no-op if exists
  for _, file in ipairs(files) do
    local tmp = os.tmpname()
    vim.system({ "curl", "-fsSL", "-o", tmp, file.url }, {}, function(r)
      if r.code == 0 then
        -- Copy to destination (can't rename across filesystems)
        local src = io.open(tmp, "r")
        if src then
          local data = src:read("*a")
          src:close()
          local dst = io.open(file.dest, "w")
          if dst then dst:write(data); dst:close() end
        end
      else
        all_ok = false
      end
      pcall(os.remove, tmp)
      finish_fetch()
    end)
  end
end

--- Check if the cached registry is missing or older than 7 days.
--- @return boolean
function M.needs_refresh()
  local stat = vim.uv.fs_stat(cache_dir .. "/parsers.toml")
  if not stat then return true end
  return os.difftime(os.time(), stat.mtime.sec) / 86400 > 1
end

--- Resolve a language to parser info.
--- Priority: user overrides → cached registry → heuristic.
--- @param lang string
--- @return arborist.ParserInfo
function M.resolve(lang)
  local overrides = config.values.overrides
  if overrides[lang] then return overrides[lang] end

  M.load()
  if entries and entries[lang] then return entries[lang] end

  -- Heuristic: try standard orgs with underscore→hyphen conversion
  local hyphenated = lang:gsub("_", "-")
  return {
    url = "https://github.com/tree-sitter-grammars/tree-sitter-" .. hyphenated,
    fallback_url = "https://github.com/tree-sitter/tree-sitter-" .. hyphenated,
  }
end

--- Resolve with async registry fetch fallback.
--- Called when heuristic clone fails — fetches registry and retries lookup.
--- @param lang string
--- @param callback fun(info: arborist.ParserInfo?)
function M.resolve_async(lang, callback)
  M.load()
  if entries and entries[lang] then
    callback(entries[lang])
    return
  end
  M.fetch(function(ok)
    if ok and entries and entries[lang] then
      callback(entries[lang])
    else
      callback(nil)
    end
  end)
end

return M

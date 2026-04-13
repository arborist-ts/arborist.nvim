--- Parser registry: load bundled data, resolve parser URLs, register filetypes.
--- Registry data is bundled with the plugin in the registry/ directory.
---
--- Two layers:
---   parsers.toml    — editor-neutral metadata from arborist-ts/registry
---                     (url, location, branch, generate, maintainers,
---                     requires, readme_note). Pulled via sync-upstream.sh.
---   pins.toml       — nvim-specific revision pins (SHA or semver tag),
---                     produced by scripts/sync-pins.lua. Overrides may be
---                     marked `override = true` to survive sync runs.
---
---   filetypes.toml  — Neovim filetype → parser name (Neovim-specific)
---   ignore.toml     — Neovim filetypes to skip (Neovim-specific)
---
--- TOML parsing is minimal and purpose-built for these formats. Strings,
--- arrays-of-strings, and booleans only — no nested tables, no multi-line.

local config = require("arborist.config")

--- @class arborist.ParserInfo
--- @field url string Git repository URL
--- @field location? string Subdirectory within repo (mono-repos)
--- @field branch? string Non-default git branch hosting the grammar (rare)
--- @field generate? boolean Whether `tree-sitter generate` runs before build
--- @field maintainers? string[] GitHub @-handles
--- @field requires? string[] Other parsers this grammar depends on
--- @field readme_note? string Human-readable note (gotchas, scope)
--- @field revision? string Commit SHA or tag (from pins.toml)
--- @field fallback_url? string Secondary URL to try (heuristic resolve only)

local M = {}

--- @type table<string, arborist.ParserInfo>?
local entries = nil
--- @type table<string, string>? lang -> revision
local pins = nil

local registry_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h") .. "/registry"
local filetypes_registered = false

-- ── Minimal TOML reader ─────────────────────────────────────────────────

--- Parse one TOML value: "string" | true/false | ["a", "b"]. Returns nil
--- on unsupported shapes (caller treats nil as "skip this line").
local function parse_value(val)
  -- string
  local s = val:match('^"(.*)"$')
  if s then return (s:gsub('\\"', '"'):gsub("\\\\", "\\")) end
  -- boolean
  if val == "true" then return true end
  if val == "false" then return false end
  -- array of strings
  local arr = val:match("^%[(.*)%]$")
  if arr then
    local out = {}
    for item in arr:gmatch('"([^"]*)"') do
      out[#out + 1] = item
    end
    return out
  end
  return nil
end

--- Parse a section-keyed TOML file: `[name]` headers with `key = value` lines.
--- @param path string
--- @return table<string, table>?
local function read_sectioned(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local result = {}
  local current
  for line in f:lines() do
    local section = line:match("^%[([%w_]+)%]$")
    if section then
      current = section
      result[current] = result[current] or {}
    elseif current then
      local key, val = line:match("^([%w_]+)%s*=%s*(.+)$")
      if key and val then
        local parsed = parse_value(vim.trim(val))
        if parsed ~= nil then result[current][key] = parsed end
      end
    end
  end
  f:close()
  return next(result) and result or nil
end

--- Parse parsers.toml: drop entries that lack url (pre-section comments etc.).
--- @param path string
--- @return table<string, arborist.ParserInfo>?
local function read_parsers(path)
  local result = read_sectioned(path)
  if not result then return nil end
  for lang, info in pairs(result) do
    if not info.url then result[lang] = nil end
  end
  return next(result) and result or nil
end

--- Parse pins.toml: extract { lang -> revision }.
--- @param path string
--- @return table<string, string>
local function read_pins(path)
  local result = read_sectioned(path)
  if not result then return {} end
  local out = {}
  for lang, info in pairs(result) do
    if info.revision then out[lang] = info.revision end
  end
  return out
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
      for ft in arr:gmatch('"([^"]+)"') do
        fts[#fts + 1] = ft
      end
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

-- ── Public API ──────────────────────────────────────────────────────────

--- Register filetype → parser mappings with Neovim. Idempotent.
function M.register_filetypes()
  if filetypes_registered then return end
  local ft_map = read_filetypes(registry_dir .. "/filetypes.toml")
  if not next(ft_map) then return end
  filetypes_registered = true
  for lang, fts in pairs(ft_map) do
    vim.treesitter.language.register(lang, fts)
  end
end

--- Load default ignore list from bundled ignore.toml.
--- @return string[]
function M.load_ignore() return read_ignore(registry_dir .. "/ignore.toml") end

--- Load bundled parser registry + pins. Registers filetypes if found.
--- @return boolean loaded
function M.load()
  if entries then return true end
  entries = read_parsers(registry_dir .. "/parsers.toml")
  pins = read_pins(registry_dir .. "/pins.toml")
  if entries then
    M.register_filetypes()
    return true
  end
  return false
end

--- Resolve a language to parser info.
--- Priority: user overrides → bundled registry merged with pins → heuristic.
--- @param lang string
--- @return arborist.ParserInfo
function M.resolve(lang)
  local overrides = config.values.overrides
  if overrides[lang] then return overrides[lang] end

  M.load()
  if entries and entries[lang] then
    local info = vim.deepcopy(entries[lang])
    if pins and pins[lang] then info.revision = pins[lang] end
    return info
  end

  -- Heuristic: try standard orgs with underscore→hyphen conversion.
  local hyphenated = lang:gsub("_", "-")
  return {
    url = "https://github.com/tree-sitter-grammars/tree-sitter-" .. hyphenated,
    fallback_url = "https://github.com/tree-sitter/tree-sitter-" .. hyphenated,
  }
end

return M

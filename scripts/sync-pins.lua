#!/usr/bin/env -S nvim -l
--- Sync nvim-specific parser revision pins from nvim-treesitter `main`.
---
--- Pins live in arborist.nvim because they're nvim-specific decisions:
--- each pin selects a SHA whose grammar is compatible with arborist's
--- bundled queries and the current tree-sitter ABI. The editor-neutral
--- registry (arborist-ts/registry) deliberately does NOT carry pins.
---
--- Reads main's parsers.lua, extracts revisions, merges with existing
--- pins.toml. Entries marked `override = true` are preserved across
--- syncs so manual decisions (e.g., holding Python at an older SHA
--- because newer grammars break our bundled query) survive upstream
--- bumps.
---
--- Usage: nvim -l scripts/sync-pins.lua

local PARSERS_URL = "https://raw.githubusercontent.com/nvim-treesitter/nvim-treesitter/main/lua/nvim-treesitter/parsers.lua"

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local plugin_root = vim.fn.fnamemodify(script_dir, ":h")
local pins_path = plugin_root .. "/registry/pins.toml"

--- @param url string
--- @return string?
local function fetch(url)
  local r = vim.system({ "curl", "-fsSL", url }, { text = true }):wait()
  if r.code ~= 0 then return nil end
  return r.stdout
end

--- Sandbox-load main's parsers.lua. The file is `return { ... }` with no
--- side effects — empty env is sufficient.
--- @param text string
--- @return table<string, table>
local function parse_parsers(text)
  local fn, err = loadstring(text, "parsers.lua")
  if not fn then
    io.stderr:write("loadstring failed: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  setfenv(fn, setmetatable({}, {
    __index = function() return nil end,
    __newindex = function() end,
  }))
  local ok, entries = pcall(fn)
  if not ok or type(entries) ~= "table" then
    io.stderr:write("evaluating parsers.lua failed: " .. tostring(entries) .. "\n")
    os.exit(1)
  end
  return entries
end

--- Read existing pins.toml. Returns a table of { [lang] = { revision, override?, comment? } }.
--- Comments and blank lines that appear between a section's data lines and
--- the next `[name]` header attach to the CURRENT section so they round-trip
--- through sync runs.
--- @param path string
--- @return table<string, {revision: string?, override: boolean, comment: string}>
local function read_pins(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local result = {}
  local current
  local pending = {} -- comment/blank lines for the current section
  local function flush()
    if current then
      result[current].comment = (result[current].comment or "") .. table.concat(pending, "\n")
    end
    pending = {}
  end
  for line in f:lines() do
    local section = line:match("^%[([%w_]+)%]$")
    if section then
      flush() -- attach pending comments to the OUTGOING section
      current = section
      result[current] = result[current] or { override = false, comment = "" }
    elseif current then
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed:match("^#") or trimmed == "" then
        pending[#pending + 1] = line
      else
        local key, val = trimmed:match("^([%w_]+)%s*=%s*(.+)$")
        if key == "revision" then
          result[current].revision = val:match('^"(.*)"$') or val
        elseif key == "override" then
          result[current].override = (val == "true")
        end
      end
    end
    -- Lines before the first section are ignored (they're the file header).
  end
  flush()
  f:close()
  return result
end

--- @param path string
--- @param content string
local function atomic_write(path, content)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    io.stderr:write("Cannot write " .. tmp .. "\n")
    os.exit(1)
  end
  f:write(content)
  f:close()
  os.rename(tmp, path)
end

-- ── Run ─────────────────────────────────────────────────────────────────

io.write("Fetching parsers.lua... ")
local text = fetch(PARSERS_URL)
if not text then
  io.write("FAILED\n")
  os.exit(1)
end
io.write("OK\n")

local upstream = parse_parsers(text)
local existing = read_pins(pins_path)

-- Build the merged pin set.
--   * For each lang in upstream: if existing override → keep it; else use upstream revision.
--   * For each lang in existing not in upstream: keep (orphan, log warning).
local merged = {}      --- @type table<string, {revision: string, override: boolean, comment: string}>
local added, updated, unchanged, kept_override, orphans = 0, 0, 0, 0, 0

for lang, entry in pairs(upstream) do
  local rev = entry.install_info and entry.install_info.revision
  if rev then
    local prev = existing[lang]
    if prev and prev.override then
      merged[lang] = { revision = prev.revision, override = true, comment = prev.comment or "" }
      kept_override = kept_override + 1
    elseif prev and prev.revision == rev then
      merged[lang] = { revision = rev, override = false, comment = prev.comment or "" }
      unchanged = unchanged + 1
    elseif prev then
      merged[lang] = { revision = rev, override = false, comment = prev.comment or "" }
      updated = updated + 1
    else
      merged[lang] = { revision = rev, override = false, comment = "" }
      added = added + 1
    end
  end
end

for lang, entry in pairs(existing) do
  if not merged[lang] and entry.revision then
    -- Orphan: kept in pins but not in upstream. Preserve so manual entries don't vanish.
    merged[lang] = entry
    orphans = orphans + 1
    io.write("  orphan (not in upstream): " .. lang .. "\n")
  end
end

-- Sort and emit.
local sorted = {}
for lang in pairs(merged) do
  sorted[#sorted + 1] = lang
end
table.sort(sorted)

local lines = {
  "# nvim-specific tree-sitter parser revision pins.",
  "#",
  "# Each pin selects a SHA whose grammar is compatible with arborist's bundled",
  "# queries and the current tree-sitter ABI. Generated by scripts/sync-pins.lua;",
  "# entries with `override = true` are preserved across sync runs.",
  "#",
  string.format("# %s | %d pins | synced from nvim-treesitter main", os.date("%Y-%m-%d"), #sorted),
  "",
}
for _, lang in ipairs(sorted) do
  local p = merged[lang]
  lines[#lines + 1] = "[" .. lang .. "]"
  lines[#lines + 1] = 'revision = "' .. p.revision .. '"'
  if p.override then lines[#lines + 1] = "override = true" end
  if p.comment and p.comment ~= "" then
    -- Drop leading/trailing blank lines and re-indent each comment line.
    local trimmed = p.comment:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then
      for cline in (trimmed .. "\n"):gmatch("([^\n]*)\n") do
        if cline:match("^#") then lines[#lines + 1] = cline end
      end
    end
  end
  lines[#lines + 1] = ""
end

atomic_write(pins_path, table.concat(lines, "\n"))

io.write(string.format(
  "Wrote %d pins (%d added, %d updated, %d unchanged, %d overrides preserved, %d orphans)\n",
  #sorted, added, updated, unchanged, kept_override, orphans
))

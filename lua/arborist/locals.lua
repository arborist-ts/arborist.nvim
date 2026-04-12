--- Minimal locals-scope lookup for tree-sitter `#is?` / `#is-not?` predicates.
--- Mirrors the practical semantics of nvim-treesitter's locals: an identifier
--- is "local" when some `@local.definition[.kind]` with the same text exists
--- in an enclosing `@local.scope` (or at the root, when no scope encloses it).

local M = {}

local cache = setmetatable({}, { __mode = "v" })

local function node_contains(outer, inner)
  local sr, sc, er, ec = outer:range()
  local ir, ic, jr, jc = inner:range()
  if sr > ir or (sr == ir and sc > ic) then return false end
  if er < jr or (er == jr and ec < jc) then return false end
  return true
end

local function smallest_enclosing(scopes, node)
  local best, best_lines
  for _, s in ipairs(scopes) do
    if node_contains(s, node) then
      local sr, _, er = s:range()
      local lines = er - sr
      if not best or lines < best_lines then
        best, best_lines = s, lines
      end
    end
  end
  return best
end

local function build(bufnr)
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or not parser then return nil end
  local lang = parser:lang()
  local query = vim.treesitter.query.get(lang, "locals")
  if not query then return { scopes = {}, defs = {} } end

  local trees = parser:parse()
  if not trees or not trees[1] then return { scopes = {}, defs = {} } end
  local root = trees[1]:root()

  local scopes, defs = {}, {}
  for id, node in query:iter_captures(root, bufnr, 0, -1) do
    local cname = query.captures[id]
    if cname == "local.scope" then
      table.insert(scopes, node)
    elseif cname == "local.definition" or cname:sub(1, 17) == "local.definition." then
      local kind = cname:sub(18)
      if kind == "" then kind = "definition" end
      table.insert(defs, { node = node, kind = kind })
    end
  end
  return { scopes = scopes, defs = defs }
end

local function get(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local entry = cache[bufnr]
  if entry and entry.tick == tick then return entry.data end
  local data = build(bufnr)
  cache[bufnr] = { tick = tick, data = data }
  return data
end

--- Return true iff `node` has a definition (matching its text) reachable from
--- its position via the locals-scope tree. `kind` is the captured definition
--- kind (e.g. "var", "parameter") or `nil` when no definition is in scope.
function M.find_definition_kind(node, bufnr)
  if not node then return nil end
  local data = get(bufnr)
  if not data then return nil end
  local ok, name = pcall(vim.treesitter.get_node_text, node, bufnr)
  if not ok or not name or name == "" then return nil end

  for _, def in ipairs(data.defs) do
    local ok2, def_text = pcall(vim.treesitter.get_node_text, def.node, bufnr)
    if ok2 and def_text == name then
      local def_scope = smallest_enclosing(data.scopes, def.node)
      if def_scope == nil or node_contains(def_scope, node) then
        return def.kind
      end
    end
  end
  return nil
end

return M

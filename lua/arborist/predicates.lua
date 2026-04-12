--- Register tree-sitter query predicate/directive handlers not built into Neovim.
--- Called once during setup(), before any vim.treesitter.start().

local M = {}

function M.register()
  local query = vim.treesitter.query

  -- #kind-eq? @capture "type1" "type2" ...
  -- True when the captured node's type matches any of the given strings.
  local function kind_eq(match, _, _, pred)
    local nodes = match[pred[2]]
    if not nodes then return false end
    for _, node in ipairs(nodes) do
      local kind = node:type()
      for i = 3, #pred do
        if kind == pred[i] then return true end
      end
    end
    return false
  end

  pcall(query.add_predicate, "kind-eq?", kind_eq, { force = false })
  pcall(query.add_predicate, "not-kind-eq?", function(...) return not kind_eq(...) end, { force = false })

  -- #is? @capture "kind1" "kind2" ... — true when @capture has a locals-scope
  -- definition whose kind matches one of the args. The bare form `#is? @x local`
  -- is treated as "@x has any definition in scope" (the dominant convention in
  -- ruby/javascript/etc. highlights). `#is-not?` is the negation.
  local locals = require("arborist.locals")
  local function is(match, _, bufnr, pred)
    local nodes = match[pred[2]]
    if not nodes or #nodes == 0 then return false end
    for _, node in ipairs(nodes) do
      local kind = locals.find_definition_kind(node, bufnr)
      if kind then
        if #pred < 3 then return true end
        if pred[3] == "local" then return true end
        for i = 3, #pred do
          if kind == pred[i] then return true end
        end
      end
    end
    return false
  end

  pcall(query.add_predicate, "is?", is, { force = false })
  pcall(query.add_predicate, "is-not?", function(...) return not is(...) end, { force = false })
end

return M

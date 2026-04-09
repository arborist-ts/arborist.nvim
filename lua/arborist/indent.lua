--- Minimal tree-sitter indentation evaluator.
--- Core algorithm derived from nvim-treesitter (Apache 2.0).

local M = {}

function M.indentexpr()
  local lnum, bufnr = vim.v.lnum, vim.api.nvim_get_current_buf()
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return -1 end
  parser:parse({ vim.fn.line("w0") - 1, vim.fn.line("w$") })
  local tree = parser:trees()[1]
  if not tree then return 0 end
  local root = tree:root()
  local query = vim.treesitter.query.get(parser:lang(), "indents")
  if not query then return -1 end

  -- Build node-id -> set-of-capture-names
  local cap = {} ---@type table<integer, table<string, true>>
  for id, node in query:iter_captures(root, bufnr) do
    local name = query.captures[id]
    if name:sub(1, 1) ~= "_" then
      local nid = node:id()
      if not cap[nid] then cap[nid] = {} end
      cap[nid][name] = true
    end
  end

  -- Reference node: last node on prev non-blank line (blank) or first node (non-blank)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local node ---@type TSNode?
  if line:find("^%s*$") then
    local prev = vim.fn.prevnonblank(lnum)
    if prev == 0 then return 0 end
    local pl = vim.api.nvim_buf_get_lines(bufnr, prev - 1, prev, false)[1] or ""
    local _, ic = pl:find("^%s*")
    local ec = ic + #vim.trim(pl) - 1
    node = root:descendant_for_range(prev - 1, ec, prev - 1, ec)
    if node and (cap[node:id()] or {})["indent.end"] then
      node = root:descendant_for_range(lnum - 1, 0, lnum - 1, 0)
    end
  else
    local _, col = line:find("^%s*")
    node = root:descendant_for_range(lnum - 1, col, lnum - 1, col + 1)
  end

  -- Walk ancestors, accumulate indent
  local indent, sw, seen = 0, vim.fn.shiftwidth(), {}
  while node do
    local srow, _, erow = node:range()
    local c = cap[node:id()]
    if c and not seen[srow] then
      local did = false
      if c["indent.branch"] and srow == lnum - 1 then indent = indent - sw; did = true end
      if c["indent.dedent"] and srow ~= lnum - 1 then indent = indent - sw; did = true end
      local is_in_err = node:parent() and node:parent():has_error()
      if c["indent.begin"] and (srow ~= erow or is_in_err) and srow ~= lnum - 1 then
        indent = indent + sw; did = true
      end
      if did then seen[srow] = true end
    end
    node = node:parent()
  end

  return indent
end

return M

--- Build backends: clone repos, download/compile parsers, copy queries.
--- Functions in this module are async (use vim.system callbacks).
--- Functions marked "main thread only" must be called from vim.schedule.

local config = require("arborist.config")

local M = {}

--- Truncate and clean command output for inclusion in error messages.
--- @param r vim.SystemCompleted
--- @return string
local function cmd_output(r)
  local out = vim.trim((r.stderr or "") .. (r.stdout or ""))
  if #out > 200 then out = out:sub(1, 200) .. "..." end
  return out
end

--- Recursively remove a directory. Safe from any thread (pure Lua + uv).
--- @param path string
local function rm_rf(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return end
  if stat.type == "directory" then
    local handle = vim.uv.fs_scandir(path)
    if handle then
      while true do
        local name, t = vim.uv.fs_scandir_next(handle)
        if not name then break end
        local child = path .. "/" .. name
        if t == "directory" then rm_rf(child) else vim.uv.fs_unlink(child) end
      end
    end
    vim.uv.fs_rmdir(path)
  else
    vim.uv.fs_unlink(path)
  end
end

--- Check that a directory contains a valid git clone.
--- @param path string
--- @return boolean
local function valid_clone(path)
  local stat = vim.uv.fs_stat(path .. "/.git")
  return stat ~= nil and stat.type == "directory"
end

--- Check that a file exists and is non-trivial. Safe in any context (pure Lua IO).
--- @param path string
--- @return boolean
local function valid_file(path)
  local f = io.open(path, "rb")
  if not f then return false end
  local size = f:seek("end")
  f:close()
  return size ~= nil and size > 100
end

-- Clone deduplication: concurrent clones to the same URL share one git operation.
local cloning = {} --- @type table<string, fun(err: string?, path: string?)[]>

--- Shallow-clone a repo. Tries primary URL, then fallback_url if present.
--- Concurrent callers for the same URL are queued behind one clone.
--- @param info arborist.ParserInfo
--- @param cache_dir string
--- @param callback fun(err: string?, path: string?)
function M.clone_repo(info, cache_dir, callback)
  local url = info.url
  local name = url:match("([^/]+)$")
  local dest = cache_dir .. "/" .. name

  -- Dedup: queue behind in-flight clone of same URL. Must check BEFORE
  -- valid_clone — git creates .git early in the clone, so valid_clone can
  -- return true for an incomplete clone that's still downloading files.
  if cloning[url] then
    cloning[url][#cloning[url] + 1] = callback
    return
  end

  -- Already cloned?
  if valid_clone(dest) then
    callback(nil, dest)
    return
  end

  rm_rf(dest) -- safe: no in-flight clone for this URL
  cloning[url] = { callback }

  local function finish(err, path)
    local cbs = cloning[url]
    cloning[url] = nil
    for _, cb in ipairs(cbs) do cb(err, path) end
  end

  local function try(clone_url, clone_dest, on_fail)
    vim.system(
      { "git", "clone", "--depth", "1", "--single-branch", "--quiet", clone_url, clone_dest },
      {},
      function(r)
        if r.code == 0 then
          finish(nil, clone_dest)
        elseif on_fail then
          on_fail()
        else
          finish("clone failed: " .. clone_url .. "\n" .. cmd_output(r))
        end
      end
    )
  end

  if info.fallback_url then
    try(url, dest, function()
      local fb_name = info.fallback_url:match("([^/]+)$")
      local fb_dest = cache_dir .. "/" .. fb_name
      if valid_clone(fb_dest) then
        finish(nil, fb_dest)
      else
        try(info.fallback_url, fb_dest)
      end
    end)
  else
    try(url, dest)
  end
end


--- Resolve the grammar root directory.
--- @return string? base  nil if location subdirectory doesn't exist
local function resolve_base(repo_path, info)
  local base = info.location and (repo_path .. "/" .. info.location) or repo_path
  if vim.uv.fs_stat(base) then return base end
  return nil
end

--- Build WASM parser via tree-sitter CLI. Requires tree-sitter + wasi-sdk.
--- @param repo_path string
--- @param info arborist.ParserInfo
--- @param dest string Output .wasm path
--- @param callback fun(err: string?)
function M.build_wasm(repo_path, info, dest, callback)
  local base = resolve_base(repo_path, info)
  if not base then callback("incomplete clone for " .. (info.location or repo_path)); return end
  vim.system({ "tree-sitter", "build", "--wasm", "-o", dest }, { cwd = base }, function(r)
    if r.code == 0 and valid_file(dest) then
      callback(nil)
    else
      pcall(os.remove, dest)
      callback("WASM build failed for " .. base .. "\n" .. cmd_output(r))
    end
  end)
end

--- Build native .so parser.
--- Primary: tree-sitter CLI (handles generate + compile).
--- Fallback: raw cc (only if parser.c already exists).
--- @param repo_path string
--- @param info arborist.ParserInfo
--- @param dest string Output .so path
--- @param callback fun(err: string?)
function M.build_native(repo_path, info, dest, callback)
  local base = resolve_base(repo_path, info)
  if not base then callback("incomplete clone for " .. (info.location or repo_path)); return end

  local function do_build()
    vim.system({ "tree-sitter", "build", "-o", dest }, { cwd = base }, function(r)
      if r.code == 0 and valid_file(dest) then
        callback(nil)
        return
      end
      pcall(os.remove, dest)
      -- Fallback: raw cc compile (main thread for vim.fn access)
      vim.schedule(function()
        local src = base .. "/src"
        if vim.fn.filereadable(src .. "/parser.c") == 0 then
          callback("build failed for " .. base)
          return
        end
        local sources = { src .. "/parser.c" }
        local link_cpp = false
        if vim.fn.filereadable(src .. "/scanner.cc") == 1 then
          sources[#sources + 1] = src .. "/scanner.cc"
          link_cpp = true
        elseif vim.fn.filereadable(src .. "/scanner.c") == 1 then
          sources[#sources + 1] = src .. "/scanner.c"
        end
        local cmd = { config.values.compiler, "-shared", "-fPIC", "-O2", "-I", src }
        vim.list_extend(cmd, sources)
        if link_cpp then cmd[#cmd + 1] = "-lstdc++" end
        vim.list_extend(cmd, { "-o", dest })
        vim.system(cmd, {}, function(r2)
          if r2.code == 0 then
            callback(nil)
          else
            pcall(os.remove, dest)
            callback("cc compile failed for " .. base .. "\n" .. cmd_output(r2))
          end
        end)
      end)
    end)
  end

  -- Generate parser.c if missing (some grammars only ship grammar.js)
  local stat = vim.uv.fs_stat(base .. "/src/parser.c")
  if stat then
    do_build()
  else
    vim.system({ "tree-sitter", "generate" }, { cwd = base }, function(r)
      if r.code ~= 0 then
        callback("tree-sitter generate failed for " .. base .. "\n" .. cmd_output(r))
        return
      end
      do_build()
    end)
  end
end

--- Copy query files (.scm) from a cloned repo into the Neovim queries directory.
--- MAIN THREAD ONLY — uses vim.fn for directory operations.
--- @param repo_path string
--- @param lang string
--- @param info arborist.ParserInfo
--- @param query_dir string
function M.copy_queries(repo_path, lang, info, query_dir)
  local base = info.location and (repo_path .. "/" .. info.location) or repo_path
  local src = base .. "/queries"
  if vim.fn.isdirectory(src) == 0 then return end

  local dest = query_dir .. "/" .. lang
  vim.fn.mkdir(dest, "p")

  for _, path in ipairs(vim.fn.glob(src .. "/*.scm", false, true)) do
    local name = vim.fn.fnamemodify(path, ":t")
    local inp = io.open(path, "r")
    if inp then
      local data = inp:read("*a")
      inp:close()
      local out = io.open(dest .. "/" .. name, "w")
      if out then out:write(data); out:close() end
    end
  end
end

return M

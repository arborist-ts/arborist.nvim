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
  local s = vim.uv.fs_stat(path)
  if not s then return end
  if s.type ~= "directory" then return vim.uv.fs_unlink(path) end
  local h = vim.uv.fs_scandir(path)
  if h then
    while true do
      local name, t = vim.uv.fs_scandir_next(h)
      if not name then break end
      local child = path .. "/" .. name
      if t == "directory" then rm_rf(child) else vim.uv.fs_unlink(child) end
    end
  end
  vim.uv.fs_rmdir(path)
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

--- Sync a repo clone to a specific git revision. Assumes a valid clone
--- at `dest`. Handles both shallow and full clones: tries checkout first,
--- and if the SHA isn't present (shallow clone), unshallows and retries.
--- @param dest string
--- @param revision string  commit SHA or tag
--- @param callback fun(err: string?)
local function ensure_revision(dest, revision, callback)
  vim.system({ "git", "-C", dest, "rev-parse", "HEAD" }, {}, function(r_head)
    if r_head.code == 0 and vim.trim(r_head.stdout or "") == revision then
      callback(nil)
      return
    end
    -- Try direct checkout first (works if full clone OR SHA is in history).
    vim.system({ "git", "-C", dest, "checkout", "--quiet", "--detach", revision }, {}, function(r_co)
      if r_co.code == 0 then
        callback(nil)
        return
      end
      -- Shallow clone doesn't have the SHA locally — unshallow then retry.
      vim.system({ "git", "-C", dest, "fetch", "--unshallow", "--quiet" }, {}, function(r_fetch)
        -- If already a full clone, `--unshallow` errors; fall through either way.
        local _ = r_fetch
        vim.system({ "git", "-C", dest, "fetch", "--quiet", "origin", revision }, {}, function(r_fetch2)
          local _ = r_fetch2
          vim.system({ "git", "-C", dest, "checkout", "--quiet", "--detach", revision }, {}, function(r_co2)
            if r_co2.code == 0 then
              callback(nil)
            else
              callback("checkout " .. revision .. " failed in " .. dest .. "\n" .. cmd_output(r_co2))
            end
          end)
        end)
      end)
    end)
  end)
end

--- Clone a repo. Tries primary URL, then fallback_url if present. If
--- info.revision is set, clones fully (not shallow) and checks out the
--- pinned SHA. Concurrent callers for the same URL are queued behind
--- one clone.
--- @param info arborist.ParserInfo
--- @param cache_dir string
--- @param callback fun(err: string?, path: string?)
--- @param on_pid? fun(pid: integer)  called with the git process PID right after clone starts
function M.clone_repo(info, cache_dir, callback, on_pid)
  local url = info.url
  local revision = info.revision -- optional pin
  local name = url:match("([^/]+)$")
  local dest = cache_dir .. "/" .. name

  -- Dedup: queue behind in-flight clone of same URL. Must check BEFORE
  -- valid_clone — git creates .git early in the clone, so valid_clone can
  -- return true for an incomplete clone that's still downloading files.
  if cloning[url] then
    cloning[url][#cloning[url] + 1] = callback
    return
  end

  local function finish_path(path)
    local cbs = cloning[url] or { callback }
    cloning[url] = nil
    for _, cb in ipairs(cbs) do cb(nil, path) end
  end
  local function finish_err(err)
    local cbs = cloning[url] or { callback }
    cloning[url] = nil
    for _, cb in ipairs(cbs) do cb(err) end
  end

  -- Already cloned? Reuse cache. If a revision is pinned, verify HEAD
  -- matches — fetch/checkout as needed to bring the cache in line.
  if valid_clone(dest) then
    cloning[url] = cloning[url] or { callback }
    if revision then
      ensure_revision(dest, revision, function(err)
        if err then finish_err(err) else finish_path(dest) end
      end)
    else
      finish_path(dest)
    end
    return
  end

  rm_rf(dest) -- safe: no in-flight clone for this URL
  cloning[url] = { callback }

  local function try(clone_url, clone_dest, on_fail)
    -- Shallow clone by default (fast, small disk). If a revision is
    -- pinned, clone fully so we can checkout arbitrary SHAs without
    -- needing to unshallow on every install.
    local args = revision
        and { "git", "clone", "--quiet", clone_url, clone_dest }
      or { "git", "clone", "--depth", "1", "--single-branch", "--quiet", clone_url, clone_dest }
    local handle = vim.system(args, {}, function(r)
      if r.code ~= 0 then
        if on_fail then on_fail() else finish_err("clone failed: " .. clone_url .. "\n" .. cmd_output(r)) end
        return
      end
      if revision then
        ensure_revision(clone_dest, revision, function(err)
          if err then finish_err(err) else finish_path(clone_dest) end
        end)
      else
        finish_path(clone_dest)
      end
    end)
    if on_pid then on_pid(handle.pid) end
  end

  if info.fallback_url then
    try(url, dest, function()
      local fb_name = info.fallback_url:match("([^/]+)$")
      local fb_dest = cache_dir .. "/" .. fb_name
      if valid_clone(fb_dest) then
        if revision then
          ensure_revision(fb_dest, revision, function(err)
            if err then finish_err(err) else finish_path(fb_dest) end
          end)
        else
          finish_path(fb_dest)
        end
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
          callback("build failed for " .. base); return
        end
        local sources, link_cpp = { src .. "/parser.c" }, false
        if vim.fn.filereadable(src .. "/scanner.cc") == 1 then
          sources[#sources + 1] = src .. "/scanner.cc"; link_cpp = true
        elseif vim.fn.filereadable(src .. "/scanner.c") == 1 then
          sources[#sources + 1] = src .. "/scanner.c"
        end
        local cmd = { config.values.compiler, "-shared", "-fPIC", "-O2", "-I", src }
        vim.list_extend(cmd, sources)
        if link_cpp then cmd[#cmd + 1] = "-lstdc++" end
        vim.list_extend(cmd, { "-o", dest })
        vim.system(cmd, {}, function(r2)
          if r2.code ~= 0 then pcall(os.remove, dest) end
          callback(r2.code ~= 0 and "cc compile failed for " .. base .. "\n" .. cmd_output(r2) or nil)
        end)
      end)
    end)
  end

  -- Generate parser.c if missing (some grammars only ship grammar.js)
  if vim.uv.fs_stat(base .. "/src/parser.c") then
    do_build()
  else
    vim.system({ "tree-sitter", "generate" }, { cwd = base }, function(r)
      if r.code ~= 0 then callback("tree-sitter generate failed for " .. base .. "\n" .. cmd_output(r))
      else do_build() end
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
    vim.uv.fs_copyfile(path, dest .. "/" .. vim.fn.fnamemodify(path, ":t"))
  end
end

return M

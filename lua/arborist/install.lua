--- Install orchestrator: clone repos, build parsers with fallback chain.
---   1. tree-sitter build --wasm  (if prefer_wasm and wasm supported)
---   2. tree-sitter build         (native .so)
---   3. cc compile                (fallback if tree-sitter CLI unavailable)
---   4. Fail
---
--- Batch installs group parsers by repo URL so each repo is cloned once.
--- Parsers sharing a repo (e.g. typescript + tsx) build sequentially from
--- the same clone.

local config = require("arborist.config")
local compile = require("arborist.compile")
local lock = require("arborist.lock")
local log = require("arborist.log")
local registry = require("arborist.registry")

local M = {}

local ignore = {} --- @type table<string, boolean> Filetypes to never attempt

--- @type boolean? nil = unknown (not yet tested), true/false = tested
M.wasm_supported = nil

--- Paths (set by init)
local parser_dir --- @type string
local query_dir --- @type string
local repo_cache --- @type string

--- @param dirs {parser: string, query: string, repo_cache: string}
function M.init(dirs)
  parser_dir = dirs.parser
  query_dir = dirs.query
  repo_cache = dirs.repo_cache
end

local function lock_path(lang)
  return repo_cache .. "/" .. lang .. ".installing"
end

--- Check whether a parser install is in progress, possibly from another
--- Neovim instance. Reads a PID file written at install start; if the
--- PID is no longer alive the lock is stale and gets cleaned up.
--- @param lang string
--- @return boolean
function M.is_installing(lang)
  local path = lock_path(lang)
  local f = io.open(path, "r")
  if not f then return false end
  local pid = tonumber(f:read("*a"))
  f:close()
  if not pid then os.remove(path); return false end
  local alive = vim.uv.kill(pid, 0) == 0
  if not alive then os.remove(path); return false end
  return true
end

--- Atomically claim the install slot using O_CREAT|O_EXCL.
--- Returns false if another process already holds the lock.
--- @param lang string
--- @return boolean
local function mark_installing(lang)
  local fd = vim.uv.fs_open(lock_path(lang), "wx", 420)
  if not fd then return false end
  vim.uv.fs_write(fd, tostring(vim.fn.getpid()), 0)
  vim.uv.fs_close(fd)
  return true
end

--- Overwrite the lock file with a new PID (e.g. the git clone process).
--- Called after the clone starts so the lock survives Vim exiting.
--- @param lang string
--- @param pid integer
local function update_lock_pid(lang, pid)
  local fd = vim.uv.fs_open(lock_path(lang), "w", 420)
  if not fd then return end
  vim.uv.fs_write(fd, tostring(pid), 0)
  vim.uv.fs_close(fd)
end

local function unmark_installing(lang)
  pcall(os.remove, lock_path(lang))
end

--- Mark filetypes to ignore. Merges with existing.
--- @param list string[]
function M.set_ignore(list)
  for _, ft in ipairs(list) do ignore[ft] = true end
end

--- Should this lang be skipped?
--- @param lang string
--- @return boolean
function M.should_skip(lang)
  return ignore[lang] or false
end

--- Build a single parser from a cloned repo. Tries WASM first, then native.
--- @param repo_path string  Cloned repo on disk
--- @param lang string
--- @param info arborist.ParserInfo
--- @param opts {silent?: boolean}
--- @param callback fun(err: string?)
local function build_parser(repo_path, lang, info, opts, callback)
  -- Clean old artifacts
  pcall(os.remove, parser_dir .. "/" .. lang .. ".so")
  pcall(os.remove, parser_dir .. "/" .. lang .. ".wasm")

  -- Copy parser-repo queries
  vim.schedule(function()
    compile.copy_queries(repo_path, lang, info, query_dir)
  end)

  local function finish(err, mode)
    if err and opts.silent then ignore[lang] = true end
    if mode then lock.record(lang, mode) end
    unmark_installing(lang)
    callback(err)
  end

  local function try_native()
    vim.schedule(function()
      compile.build_native(repo_path, info, parser_dir .. "/" .. lang .. ".so", function(err)
        vim.schedule(function()
          finish(err, err and nil or "native")
        end)
      end)
    end)
  end

  local try_wasm = config.values.prefer_wasm and M.wasm_supported ~= false
  if try_wasm then
    local wasm_path = parser_dir .. "/" .. lang .. ".wasm"
    compile.build_wasm(repo_path, info, wasm_path, function(werr)
      if not werr then
        vim.schedule(function()
          local lok, _, lerr = pcall(vim.treesitter.language.add, lang, { path = wasm_path })
          if lok and lerr == nil then
            M.wasm_supported = true
            finish(nil, "wasm-built")
          else
            pcall(os.remove, wasm_path)
            if M.wasm_supported == nil then
              M.wasm_supported = false
              log.info("WASM parsers not supported by this Neovim build, using native compilation")
            end
            try_native()
          end
        end)
      else
        try_native()
      end
    end)
  else
    try_native()
  end
end

--- Expand a lang list to include all transitive requires deps.
--- Deps precede their dependents; duplicates are removed.
--- @param langs string[]
--- @return string[]
local function expand_required_dependencies(langs)
  local seen = {}
  local result = {}
  local function add(lang)
    if seen[lang] then return end
    seen[lang] = true
    local info = registry.resolve(lang)
    if info.requires then
      for _, dep in ipairs(info.requires) do add(dep) end
    end
    result[#result + 1] = lang
  end
  for _, lang in ipairs(langs) do add(lang) end
  return result
end

--- Install multiple parsers. Groups by repo URL — each repo is cloned once,
--- then parsers sharing that repo are built sequentially from the same clone.
--- Repo groups run in parallel.
--- @param langs string[]
--- @param callback fun(results: table<string, string?>) lang → error or nil
--- @param opts? {silent?: boolean}
function M.install_batch(langs, callback, opts)
  opts = opts or {}

  langs = expand_required_dependencies(langs)

  -- Skip langs already being installed by another process; atomically claim the rest.
  -- is_installing cleans up stale locks (dead PIDs); mark_installing uses O_EXCL
  -- so concurrent Neovim instances can't both claim the same lang.
  local active = {}
  for _, lang in ipairs(langs) do
    if not M.is_installing(lang) and mark_installing(lang) then
      active[#active + 1] = lang
    end
  end
  langs = active

  -- Resolve all parsers and group by repo URL
  --- @type table<string, {lang: string, info: arborist.ParserInfo}[]>
  local groups = {}
  local group_order = {} --- @type string[]  preserve first-seen order
  for _, lang in ipairs(langs) do
    local info = registry.resolve(lang)
    local url = info.url
    if not groups[url] then
      groups[url] = {}
      group_order[#group_order + 1] = url
    end
    groups[url][#groups[url] + 1] = { lang = lang, info = info }
  end

  local results = {} --- @type table<string, string?>
  local groups_remaining = #group_order

  if groups_remaining == 0 then callback(results); return end

  local function group_done()
    groups_remaining = groups_remaining - 1
    if groups_remaining == 0 then callback(results) end
  end

  -- Clone each unique repo, then build parsers sequentially within each repo.
  -- Concurrency limits how many repos are processed in parallel.
  local max_concurrent = config.values.concurrency or math.huge
  local active_count = 0
  local pending_urls = {} --- @type string[]

  local function start_group(url)
    active_count = active_count + 1
    local parsers = groups[url]

    compile.clone_repo(parsers[1].info, repo_cache, function(err, path)
      if err then
        for _, p in ipairs(parsers) do
          results[p.lang] = err
          unmark_installing(p.lang)
        end
        active_count = active_count - 1
        group_done()
        if #pending_urls > 0 then start_group(table.remove(pending_urls, 1)) end
        return
      end

      local function build_next(i)
        if i > #parsers then
          active_count = active_count - 1
          group_done()
          if #pending_urls > 0 then start_group(table.remove(pending_urls, 1)) end
          return
        end
        local p = parsers[i]
        build_parser(path, p.lang, p.info, opts, function(build_err)
          results[p.lang] = build_err
          if opts.progress then
            opts.progress(p.lang, build_err)
          end
          build_next(i + 1)
        end)
      end

      build_next(1)
    end, function(git_pid)
      for _, p in ipairs(parsers) do update_lock_pid(p.lang, git_pid) end
    end)
  end

  for _, url in ipairs(group_order) do
    if active_count < max_concurrent then
      start_group(url)
    else
      pending_urls[#pending_urls + 1] = url
    end
  end
end

--- Install a single parser (convenience wrapper around install_batch).
--- @param lang string
--- @param callback? fun(err: string?)
--- @param opts? {silent?: boolean}
function M.install(lang, callback, opts)
  callback = callback or function() end
  M.install_batch({ lang }, function(results)
    callback(results[lang])
  end, opts)
end

return M

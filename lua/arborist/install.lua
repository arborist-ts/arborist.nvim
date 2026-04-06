--- Install orchestrator: 4-tier fallback chain per parser.
---   1. WASM CDN download
---   2. Clone + tree-sitter build --wasm
---   3. Clone + tree-sitter build (native) or cc
---   4. Fail
--- Tiers 1-2 are skipped once wasm_supported is known false.

local config = require("arborist.config")
local compile = require("arborist.compile")
local lock = require("arborist.lock")
local log = require("arborist.log")
local registry = require("arborist.registry")

local M = {}

local active = {} --- @type table<string, boolean> In-flight installs
local waiting = {} --- @type table<string, fun(err: string?)[]> Callbacks queued behind active installs
local failed = {} --- @type table<string, boolean> Langs that failed (skip auto-retries)
local ignore = {} --- @type table<string, boolean> Filetypes to never attempt

--- @type boolean
M.wasm_supported = false

--- Paths (set by init)
local parser_dir --- @type string
local query_dir --- @type string
local repo_cache --- @type string

--- @param dirs {parser: string, query: string, repo_cache: string}
function M.init(dirs)
  parser_dir = dirs.parser
  query_dir = dirs.query
  repo_cache = dirs.repo_cache
  -- Detect WASM support: write minimal .wasm, try to load it.
  -- Instant, synchronous, runs once at startup. No network, no delay.
  M.wasm_supported = (function()
    local tmp = os.tmpname() .. ".wasm"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write("\0asm\1\0\0\0") -- minimal valid WASM header
    f:close()
    -- If Neovim has wasmtime, this fails with "invalid module" (WASM IS available).
    -- If Neovim lacks wasmtime, this fails with "wasm not supported" (WASM NOT available).
    local _, err = vim.treesitter.language.add("_arborist_probe", { path = tmp })
    os.remove(tmp)
    local msg = tostring(err or ""):lower()
    return not (msg:find("wasm") and msg:find("not"))
  end)()
end

--- Mark filetypes to ignore. Merges with existing.
--- @param list string[]
function M.set_ignore(list)
  for _, ft in ipairs(list) do ignore[ft] = true end
end

--- Should this lang be skipped by the auto-detect autocmd?
--- @param lang string
--- @return boolean
function M.should_skip(lang)
  return ignore[lang] or failed[lang] or active[lang] or false
end

--- Check if Neovim can load a parser for this language.
--- @param lang string
--- @return boolean
local function parser_loaded(lang)
  return vim.treesitter.language.add(lang) == true
end

--- Build a native .so from cloned source (via vim.schedule for main-thread safety).
--- @param repo string
--- @param lang string
--- @param info arborist.ParserInfo
--- @param callback fun(err: string?)
local function try_native(repo, lang, info, callback)
  vim.schedule(function()
    compile.build_native(repo, info, parser_dir .. "/" .. lang .. ".so", function(err)
      vim.schedule(function() callback(err) end)
    end)
  end)
end

--- Install a single parser. Safe to call concurrently for the same lang —
--- duplicate callers are queued and notified when the install finishes.
--- @param lang string
--- @param callback? fun(err: string?)
--- @param opts? {silent?: boolean}
function M.install(lang, callback, opts)
  opts = opts or {}
  callback = callback or function() end

  -- Queue behind in-flight install of same lang
  if active[lang] then
    waiting[lang] = waiting[lang] or {}
    waiting[lang][#waiting[lang] + 1] = callback
    return
  end
  active[lang] = true
  failed[lang] = nil

  -- Clean old artifacts
  pcall(os.remove, parser_dir .. "/" .. lang .. ".so")
  pcall(os.remove, parser_dir .. "/" .. lang .. ".wasm")

  if not opts.silent then log.info("Installing " .. lang .. "...") end

  local info = registry.resolve(lang)
  local try_wasm = config.values.prefer_wasm and M.wasm_supported ~= false

  local repo --- @type string?  Cloned repo path (set by clone operation)
  local wasm_cdn_ok = false --- Did CDN download succeed?
  local remaining = try_wasm and 2 or 1 --- Parallel ops to wait for

  -- Notify all callers (original + queued) and clean up state.
  local function finish(err, mode)
    active[lang] = nil
    if err then
      failed[lang] = true
      if opts.silent then ignore[lang] = true end
    end
    if mode then
      lock.record(lang, mode)
      log.info("Installed: " .. lang .. " (" .. mode .. ")")
    elseif not opts.silent then
      log.warn(err or "unknown error installing " .. lang)
    end
    callback(err)
    local queued = waiting[lang]
    waiting[lang] = nil
    if queued then
      for _, cb in ipairs(queued) do cb(err) end
    end
  end

  -- Try building from cloned repo: WASM first, then native.
  local function build_from_repo()
    if not repo then
      finish("no parser source found for " .. lang)
      return
    end
    -- Install queries on main thread
    vim.schedule(function() compile.copy_queries(repo, lang, info, query_dir) end)

    if try_wasm then
      compile.build_wasm(repo, info, parser_dir .. "/" .. lang .. ".wasm", function(werr)
        if not werr then
          finish(nil, "wasm-built")
        else
          try_native(repo, lang, info, function(nerr)
            finish(nerr, nerr and nil or "native")
          end)
        end
      end)
    else
      try_native(repo, lang, info, function(nerr)
        finish(nerr, nerr and nil or "native")
      end)
    end
  end

  -- Both parallel ops done — decide which path to take.
  local function check_done()
    remaining = remaining - 1
    if remaining > 0 then return end

    if try_wasm and wasm_cdn_ok then
      vim.schedule(function()
        if repo then compile.copy_queries(repo, lang, info, query_dir) end
        finish(nil, "wasm-cdn")
      end)
    else
      build_from_repo()
    end
  end

  -- Operation 1: Clone repo (with registry fallback on failure)
  compile.clone_repo(info, repo_cache, function(err, path)
    if not err then
      repo = path
      check_done()
      return
    end
    -- Heuristic failed — try registry for custom-org parsers
    registry.resolve_async(lang, function(reg_info)
      if reg_info then
        info = reg_info
        compile.clone_repo(reg_info, repo_cache, function(_, reg_path)
          repo = reg_path
          check_done()
        end)
      else
        check_done() -- repo stays nil → will fail in build_from_repo
      end
    end)
  end)

  -- Operation 2: WASM CDN download (parallel with clone)
  if try_wasm then
    compile.download_wasm(lang, parser_dir .. "/" .. lang .. ".wasm", function(err)
      wasm_cdn_ok = not err
      check_done()
    end)
  end
end

return M

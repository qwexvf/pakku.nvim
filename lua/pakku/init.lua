-- pakku: thin DX layer over vim.pack.
-- Public API: setup, add, update, review, scan, clean, status.
local M = {}

local Spec = require("pakku.spec")
local Loader = require("pakku.loader")
local Build = require("pakku.build")
local Scanner = require("pakku.scanner")
local Policy = require("pakku.policy")

local defaults = {
  performance = { loader = true },
  security = {
    allowlist = { "github.com", "codeberg.org", "gitlab.com", "git.sr.ht" },
    require_https = true,
    require_pinned_version = false,
  },
  scanner = {
    enabled = false,
    bin = "aegis",
    on = { "install", "update" },
    analyze = true, -- aegis analyze --ecosystem neovim (Lua AST capabilities)
    actions = true, -- aegis actions scan (GH Actions workflows)
    sbom = false, -- aegis sbom (opt-in; low signal for pure-Lua plugins)
    evidence = false, -- include --evidence flag (file:line snippets in JSON)
    fail_on = nil, -- aegis --fail-on for actions: safe|review|prompt|block
    report_dir = nil,
    -- Pre-activation gate (§2.1 of safety spec). Verdicts handled:
    --   "off"    — no gate, plugin loads regardless of verdict
    --   "block"  — refuse load when verdict == "block"
    --   "prompt" — refuse load when verdict == "block" OR "prompt"
    -- Cached by (name, rev) under report_dir/<name>-<rev>.cache.json.
    gate = "block",
    -- When true: notify for every gate decision (including allowed prompts).
    -- When false (default): only notify on BLOCK. Keeps startup quiet for
    -- legitimate plugins that report shell-spawn / env-read etc.
    verbose = false,
  },
  confirm_update = true,
}

local state = { config = vim.deepcopy(defaults) }

local function ensure_pack()
  if not vim.pack then error("pakku: vim.pack missing — requires Neovim 0.12+") end
end

local function merge(into, from)
  for k, v in pairs(from or {}) do
    if type(v) == "table" and type(into[k]) == "table" then
      merge(into[k], v)
    else
      into[k] = v
    end
  end
end

local SUBS = { "ui", "status", "scan", "update", "review", "profile", "clean" }

function M.setup(opts)
  ensure_pack()
  merge(state.config, opts or {})
  state.config.scanner.report_dir = state.config.scanner.report_dir
    or vim.fs.joinpath(vim.fn.stdpath("state"), "pakku", "scans")
  if state.config.performance.loader and vim.loader and not vim.loader.enabled then
    pcall(vim.loader.enable)
  end
  Build.attach(state.config)

  -- Fire `User VeryLazy` after startup for lazy.nvim-style specs.
  local g = vim.api.nvim_create_augroup("pakku.verylazy", { clear = true })
  local function fire()
    vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
  end
  if vim.v.vim_did_enter == 1 then
    vim.schedule(fire)
  else
    vim.api.nvim_create_autocmd(
      "VimEnter",
      { group = g, once = true, callback = function() vim.schedule(fire) end }
    )
  end

  vim.api.nvim_create_user_command("Pakku", function(args)
    local sub, rest = args.fargs[1], vim.list_slice(args.fargs, 2)
    if sub == nil or sub == "ui" then
      require("pakku.ui").open()
    elseif sub == "status" then
      M.status()
    elseif sub == "scan" then
      M.scan(rest[1])
    elseif sub == "update" then
      M.update(rest)
    elseif sub == "review" then
      M.review(rest)
    elseif sub == "profile" then
      require("pakku.profile").show()
    elseif sub == "clean" then
      M.clean(rest)
    else
      vim.notify("pakku: unknown subcommand " .. sub, vim.log.levels.ERROR)
    end
  end, {
    nargs = "*",
    complete = function(arglead, line)
      local pool = SUBS
      if not line:match("^Pakku%s+%S*$") then pool = vim.tbl_keys(Loader.by_name) end
      return vim.tbl_filter(function(s) return s:find(arglead, 1, true) == 1 end, pool)
    end,
  })
end

-- Verdict → gated? `strict` upgrades "prompt" to a block (when scanner.gate == "prompt").
local function verdict_blocks(verdict, strict)
  if verdict == "block" then return true end
  if strict and verdict == "prompt" then return true end
  return false
end

-- vim.schedule so startup-time notifications don't fire the hit-enter prompt.
local function notify_blocked(name, result)
  vim.schedule(
    function()
      vim.notify(
        ("pakku: BLOCKED %s — verdict=%s risk=%d caps=[%s]%s"):format(
          name,
          result.verdict or "?",
          result.risk_score or 0,
          table.concat(result.capabilities or {}, ", "),
          result.cached and " (cached)" or ""
        ),
        vim.log.levels.ERROR
      )
    end
  )
end

local function notify_prompt_pass(name, result, verbose)
  if not verbose then return end
  vim.schedule(
    function()
      vim.notify(
        ("pakku: %s verdict=prompt risk=%d caps=[%s] (gate=block allowed)"):format(
          name,
          result.risk_score or 0,
          table.concat(result.capabilities or {}, ", ")
        ),
        vim.log.levels.WARN
      )
    end
  )
end

local function unregister(name)
  Loader.pending[name] = nil
  Loader.by_name[name] = nil
end

local function activate_eager(spec)
  local ok, err = pcall(vim.cmd, "packadd " .. spec.name)
  if not ok then
    vim.notify(("pakku: packadd %s failed: %s"):format(spec.name, err), vim.log.levels.ERROR)
    return
  end
  Loader.apply(spec)
end

function M.add(specs)
  ensure_pack()
  local entries = Policy.filter(Spec.normalize(specs), state.config.security)
  if #entries == 0 then return end

  local scanner_cfg = state.config.scanner
  local gate_on = scanner_cfg.enabled
    and scanner_cfg.gate ~= "off"
    and vim.fn.executable(scanner_cfg.bin or "aegis") == 1
  local confirm = state.config.confirm_update

  -- Fast path: no gate active. Same flow as pre-§2.1 (eager loads at startup,
  -- lazy registers triggers). Zero blocking on the scanner.
  if not gate_on then
    for _, e in ipairs(entries) do
      Loader.register(e.lazy)
    end
    local eager, lazy_pack = {}, {}
    for _, e in ipairs(entries) do
      table.insert(e.lazy.is_lazy and lazy_pack or eager, e.lazy.is_lazy and e.pack or e)
    end
    table.sort(eager, function(a, b) return (a.lazy.priority or 50) > (b.lazy.priority or 50) end)
    local eager_pack = vim.tbl_map(function(e) return e.pack end, eager)
    if #eager_pack > 0 then vim.pack.add(eager_pack, { load = true, confirm = confirm }) end
    if #lazy_pack > 0 then vim.pack.add(lazy_pack, { load = false, confirm = confirm }) end
    for _, e in ipairs(eager) do
      Loader.apply(e.lazy)
    end
    return
  end

  -- Gated path. Install everything load=false; check cache for an instant
  -- decision; defer to async scan for cache misses.
  for _, e in ipairs(entries) do
    Loader.register(e.lazy)
  end
  local all_pack = vim.tbl_map(function(e) return e.pack end, entries)
  vim.pack.add(all_pack, { load = false, confirm = confirm })

  local strict = scanner_cfg.gate == "prompt"
  local immediate_eager, deferred = {}, {}

  for _, e in ipairs(entries) do
    local p = (vim.pack.get({ e.pack.name }))[1]
    if not p then
      -- Install failed; let downstream surface the error. Treat as allowed.
      if not e.lazy.is_lazy then table.insert(immediate_eager, e) end
    else
      local cached = Scanner.cache_lookup({ name = e.pack.name, rev = p.rev }, scanner_cfg)
      if cached then
        if verdict_blocks(cached.verdict, strict) then
          notify_blocked(e.pack.name, cached)
          unregister(e.pack.name)
        else
          if cached.verdict == "prompt" then
            notify_prompt_pass(e.pack.name, cached, scanner_cfg.verbose)
          end
          if not e.lazy.is_lazy then table.insert(immediate_eager, e) end
        end
      else
        -- No cache; scan async. Defer load until verdict arrives.
        table.insert(deferred, { entry = e, plugin = p })
      end
    end
  end

  -- Activate cached-OK eager plugins NOW. No blocking.
  table.sort(
    immediate_eager,
    function(a, b) return (a.lazy.priority or 50) > (b.lazy.priority or 50) end
  )
  for _, e in ipairs(immediate_eager) do
    activate_eager(e.lazy)
  end

  -- For uncached entries, run aegis async and decide on the callback.
  for _, d in ipairs(deferred) do
    Scanner.scan_async(
      { name = d.entry.pack.name, path = d.plugin.path, rev = d.plugin.rev },
      scanner_cfg,
      function(result)
        if not result then
          -- aegis errored / produced nothing: fail-open, load now.
          if not d.entry.lazy.is_lazy then activate_eager(d.entry.lazy) end
          return
        end
        if verdict_blocks(result.verdict, strict) then
          notify_blocked(d.entry.pack.name, result)
          unregister(d.entry.pack.name)
          return
        end
        if result.verdict == "prompt" then
          notify_prompt_pass(d.entry.pack.name, result, scanner_cfg.verbose)
        end
        if not d.entry.lazy.is_lazy then activate_eager(d.entry.lazy) end
      end
    )
  end
end

function M.update(names)
  ensure_pack()
  if names and #names == 0 then names = nil end
  vim.pack.update(names, { confirm = state.config.confirm_update })
end

function M.review(names)
  ensure_pack()
  if names and #names == 0 then names = nil end
  require("pakku.review").review(names)
end

function M.clean(names)
  ensure_pack()
  if not names or #names == 0 then
    return vim.notify("pakku: clean requires plugin names", vim.log.levels.WARN)
  end
  vim.pack.del(names)
end

function M.scan(name)
  if name then
    local p = (vim.pack.get({ name }))[1]
    if not p then
      return vim.notify("pakku: no installed plugin named " .. name, vim.log.levels.WARN)
    end
    Scanner.scan_one({ name = p.spec.name, path = p.path }, state.config.scanner)
  else
    Scanner.scan_all(state.config.scanner)
  end
end

function M.status()
  local lines = { "pakku status:" }
  local plugins = vim.pack.get()
  table.sort(plugins, function(a, b) return a.spec.name < b.spec.name end)
  for _, p in ipairs(plugins) do
    local n = p.spec.name
    local mark = Loader.active[n] and "[active]"
      or Loader.pending[n] and "[pending]"
      or "[unmanaged]"
    table.insert(lines, ("  %s %s  (%s)"):format(mark, n, p.rev or "?"))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

M._state = state -- for health.lua
return M

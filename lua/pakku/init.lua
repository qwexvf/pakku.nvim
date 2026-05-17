-- pakku: thin DX layer over vim.pack
-- Public API: setup, add, update, scan, status, clean
local M = {}

local Spec = require("pakku.spec")
local Loader = require("pakku.loader")
local Build = require("pakku.build")
local Scanner = require("pakku.scanner")
local Policy = require("pakku.policy")

local defaults = {
  performance = {
    loader = true,  -- vim.loader.enable() bytecode cache
  },
  security = {
    allowlist = {   -- empty = allow any host
      "github.com", "codeberg.org", "gitlab.com", "git.sr.ht",
    },
    require_https = true,        -- reject git:// and http:// schemes
    require_pinned_version = false,  -- warn (not block) when version=nil
  },
  scanner = {
    enabled = false,  -- opt-in: requires aegis on PATH
    bin = "aegis",
    on = { "install", "update" },
    actions = true,
    sbom = true,
    fail_on = nil,    -- aegis --fail-on: safe|review|prompt|block
    report_dir = nil, -- defaults to stdpath('state')/pakku/scans
  },
  confirm_update = true,  -- forward to vim.pack.update
}

local state = {
  config = vim.deepcopy(defaults),
}

local function ensure_pack()
  if not vim.pack then
    error("pakku: vim.pack missing — requires Neovim 0.12+")
  end
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

function M.setup(opts)
  ensure_pack()
  merge(state.config, opts or {})
  if state.config.scanner.report_dir == nil then
    state.config.scanner.report_dir = vim.fs.joinpath(vim.fn.stdpath("state"), "pakku", "scans")
  end
  -- vim.loader caches compiled Lua bytecode; ~10-30ms cold start win per plugin.
  if state.config.performance.loader and vim.loader and not vim.loader.enabled then
    pcall(vim.loader.enable)
  end
  -- Build.attach uses an augroup with clear=true, so calling repeatedly is safe.
  Build.attach(state.config)

  -- Fire `User VeryLazy` after startup so specs with `event = "VeryLazy"`
  -- (lazy.nvim convention) load post-init. Idempotent: augroup is cleared.
  local g = vim.api.nvim_create_augroup("pakku.verylazy", { clear = true })
  local function fire_verylazy()
    vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
  end
  if vim.v.vim_did_enter == 1 then
    vim.schedule(fire_verylazy)
  else
    vim.api.nvim_create_autocmd("VimEnter", {
      group = g, once = true,
      callback = function() vim.schedule(fire_verylazy) end,
    })
  end

  vim.api.nvim_create_user_command("Pakku", function(args)
    local sub = args.fargs[1]
    local rest = vim.list_slice(args.fargs, 2)
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
    elseif sub == "clean" then
      M.clean(rest)
    else
      vim.notify("pakku: unknown subcommand " .. sub, vim.log.levels.ERROR)
    end
  end, {
    nargs = "*",
    complete = function(arglead, line)
      local subs = { "ui", "status", "scan", "update", "review", "clean" }
      if line:match("^Pakku%s+%S*$") then
        return vim.tbl_filter(function(s) return s:find(arglead, 1, true) == 1 end, subs)
      end
      local names = {}
      for n in pairs(Loader.by_name) do table.insert(names, n) end
      return vim.tbl_filter(function(s) return s:find(arglead, 1, true) == 1 end, names)
    end,
  })
end

function M.add(specs)
  ensure_pack()
  local normalized = Spec.normalize(specs)
  normalized = Policy.filter(normalized, state.config.security)
  if #normalized == 0 then return end

  -- Single registration path: every spec lands in Loader.by_name; lazy ones also get triggers.
  for _, entry in ipairs(normalized) do
    Loader.register(entry.lazy)
  end

  local eager_entries, lazy_pack = {}, {}
  for _, entry in ipairs(normalized) do
    if entry.lazy.is_lazy then
      table.insert(lazy_pack, entry.pack)
    else
      table.insert(eager_entries, entry)
    end
  end

  -- Higher priority loads first (lazy.nvim parity). Default 50. Stable on ties.
  table.sort(eager_entries, function(a, b)
    local pa = a.lazy.priority or 50
    local pb = b.lazy.priority or 50
    return pa > pb
  end)

  local eager_pack, eager_specs = {}, {}
  for _, entry in ipairs(eager_entries) do
    table.insert(eager_pack, entry.pack)
    table.insert(eager_specs, entry.lazy)
  end

  if #eager_pack > 0 then
    vim.pack.add(eager_pack, { load = true, confirm = state.config.confirm_update })
  end
  if #lazy_pack > 0 then
    vim.pack.add(lazy_pack, { load = false, confirm = state.config.confirm_update })
  end

  for _, spec in ipairs(eager_specs) do
    Loader.apply(spec)
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
    vim.notify("pakku: clean requires plugin names", vim.log.levels.WARN)
    return
  end
  vim.pack.del(names)
end

function M.scan(name)
  if name then
    local plugins = vim.pack.get({ name })
    if #plugins == 0 then
      vim.notify("pakku: no installed plugin named " .. name, vim.log.levels.WARN)
      return
    end
    local p = plugins[1]
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
    local name = p.spec.name
    local mark
    if Loader.active[name] then mark = "[active]"
    elseif Loader.pending[name] then mark = "[pending]"
    else mark = "[unmanaged]" end
    table.insert(lines, string.format("  %s %s  (%s)", mark, name, p.rev or "?"))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

M._state = state  -- exposed for health.lua
return M

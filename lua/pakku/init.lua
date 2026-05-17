-- pakku: thin DX layer over vim.pack.
-- Public API: setup, add, update, review, scan, clean, status.
local M = {}

local Spec    = require("pakku.spec")
local Loader  = require("pakku.loader")
local Build   = require("pakku.build")
local Scanner = require("pakku.scanner")
local Policy  = require("pakku.policy")

local defaults = {
  performance = { loader = true },
  security = {
    allowlist = { "github.com", "codeberg.org", "gitlab.com", "git.sr.ht" },
    require_https = true,
    require_pinned_version = false,
  },
  scanner = {
    enabled = false, bin = "aegis",
    on = { "install", "update" },
    actions = true, sbom = true,
    fail_on = nil, report_dir = nil,
  },
  confirm_update = true,
}

local state = { config = vim.deepcopy(defaults) }

local function ensure_pack()
  if not vim.pack then error("pakku: vim.pack missing — requires Neovim 0.12+") end
end

local function merge(into, from)
  for k, v in pairs(from or {}) do
    if type(v) == "table" and type(into[k]) == "table" then merge(into[k], v) else into[k] = v end
  end
end

local SUBS = { "ui", "status", "scan", "update", "review", "clean" }

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
  local function fire() vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false }) end
  if vim.v.vim_did_enter == 1 then
    vim.schedule(fire)
  else
    vim.api.nvim_create_autocmd("VimEnter", { group = g, once = true, callback = function() vim.schedule(fire) end })
  end

  vim.api.nvim_create_user_command("Pakku", function(args)
    local sub, rest = args.fargs[1], vim.list_slice(args.fargs, 2)
    if sub == nil or sub == "ui" then require("pakku.ui").open()
    elseif sub == "status" then M.status()
    elseif sub == "scan"   then M.scan(rest[1])
    elseif sub == "update" then M.update(rest)
    elseif sub == "review" then M.review(rest)
    elseif sub == "clean"  then M.clean(rest)
    else vim.notify("pakku: unknown subcommand " .. sub, vim.log.levels.ERROR) end
  end, {
    nargs = "*",
    complete = function(arglead, line)
      local pool = SUBS
      if not line:match("^Pakku%s+%S*$") then
        pool = vim.tbl_keys(Loader.by_name)
      end
      return vim.tbl_filter(function(s) return s:find(arglead, 1, true) == 1 end, pool)
    end,
  })
end

function M.add(specs)
  ensure_pack()
  local entries = Policy.filter(Spec.normalize(specs), state.config.security)
  if #entries == 0 then return end

  for _, e in ipairs(entries) do Loader.register(e.lazy) end

  local eager, lazy_pack = {}, {}
  for _, e in ipairs(entries) do
    table.insert(e.lazy.is_lazy and lazy_pack or eager, e.lazy.is_lazy and e.pack or e)
  end

  -- Higher priority eager loads first (lazy.nvim parity). Default 50.
  table.sort(eager, function(a, b) return (a.lazy.priority or 50) > (b.lazy.priority or 50) end)

  local eager_pack = vim.tbl_map(function(e) return e.pack end, eager)
  local confirm = state.config.confirm_update
  if #eager_pack > 0 then vim.pack.add(eager_pack, { load = true,  confirm = confirm }) end
  if #lazy_pack  > 0 then vim.pack.add(lazy_pack,  { load = false, confirm = confirm }) end
  for _, e in ipairs(eager) do Loader.apply(e.lazy) end
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
    if not p then return vim.notify("pakku: no installed plugin named " .. name, vim.log.levels.WARN) end
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
    local mark = Loader.active[n] and "[active]" or Loader.pending[n] and "[pending]" or "[unmanaged]"
    table.insert(lines, ("  %s %s  (%s)"):format(mark, n, p.rev or "?"))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

M._state = state  -- for health.lua
return M

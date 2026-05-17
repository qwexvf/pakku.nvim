-- packline: thin DX layer over vim.pack
-- Public API: setup, add, update, scan, status, clean
local M = {}

local Spec = require("packline.spec")
local Loader = require("packline.loader")
local Build = require("packline.build")
local Scanner = require("packline.scanner")

local defaults = {
  scanner = {
    enabled = false,  -- opt-in: requires aegis on PATH
    bin = "aegis",
    on = { "install", "update" },
    actions = true,
    sbom = true,
    fail_on = nil,    -- aegis --fail-on: safe|review|prompt|block
    report_dir = nil, -- defaults to stdpath('state')/packline/scans
  },
  confirm_update = true,  -- forward to vim.pack.update
}

local state = {
  config = vim.deepcopy(defaults),
}

local function ensure_pack()
  if not vim.pack then
    error("packline: vim.pack missing — requires Neovim 0.12+")
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
    state.config.scanner.report_dir = vim.fs.joinpath(vim.fn.stdpath("state"), "packline", "scans")
  end
  -- Build.attach uses an augroup with clear=true, so calling repeatedly is safe.
  Build.attach(state.config)

  vim.api.nvim_create_user_command("Packline", function(args)
    local sub = args.fargs[1]
    local rest = vim.list_slice(args.fargs, 2)
    if sub == "status" or sub == nil then
      M.status()
    elseif sub == "scan" then
      M.scan(rest[1])
    elseif sub == "update" then
      M.update(rest)
    elseif sub == "clean" then
      M.clean(rest)
    else
      vim.notify("packline: unknown subcommand " .. sub, vim.log.levels.ERROR)
    end
  end, {
    nargs = "*",
    complete = function(arglead, line)
      local subs = { "status", "scan", "update", "clean" }
      if line:match("^Packline%s+%S*$") then
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

  -- Single registration path: every spec lands in Loader.by_name; lazy ones also get triggers.
  for _, entry in ipairs(normalized) do
    Loader.register(entry.lazy)
  end

  local eager_pack, lazy_pack, eager_specs = {}, {}, {}
  for _, entry in ipairs(normalized) do
    if entry.lazy.is_lazy then
      table.insert(lazy_pack, entry.pack)
    else
      table.insert(eager_pack, entry.pack)
      table.insert(eager_specs, entry.lazy)
    end
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

function M.clean(names)
  ensure_pack()
  if not names or #names == 0 then
    vim.notify("packline: clean requires plugin names", vim.log.levels.WARN)
    return
  end
  vim.pack.del(names)
end

function M.scan(name)
  if name then
    local plugins = vim.pack.get({ name })
    if #plugins == 0 then
      vim.notify("packline: no installed plugin named " .. name, vim.log.levels.WARN)
      return
    end
    local p = plugins[1]
    Scanner.scan_one({ name = p.spec.name, path = p.path }, state.config.scanner)
  else
    Scanner.scan_all(state.config.scanner)
  end
end

function M.status()
  local lines = { "packline status:" }
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

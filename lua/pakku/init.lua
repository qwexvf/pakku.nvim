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
    -- Pre-activation gate (§2.1 of safety spec). Synchronous scan before
    -- :packadd. Verdicts handled:
    --   "off"    — no gate, plugin loads regardless of verdict
    --   "block"  — refuse load when verdict == "block"
    --   "prompt" — refuse load when verdict == "block" OR "prompt"
    -- Cached by (name, rev) under report_dir/<name>-<rev>.cache.json.
    gate = "block",
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

-- Apply the pre-activation scan gate. Returns the subset of entries that
-- passed the configured verdict threshold. Plugins that fail the gate get
-- removed from the loader registry and not :packadd'd. No-op when scanner
-- is disabled or gate is "off". See safety spec §2.1.
local function gate_entries(entries, scanner_cfg)
  if not scanner_cfg.enabled or scanner_cfg.gate == "off" then return entries end
  if vim.fn.executable(scanner_cfg.bin or "aegis") ~= 1 then return entries end

  local strict = scanner_cfg.gate == "prompt"
  local kept = {}
  for _, e in ipairs(entries) do
    local p = (vim.pack.get({ e.pack.name }))[1]
    if not p then
      table.insert(kept, e) -- install incomplete; let downstream handle
    else
      local result =
        Scanner.scan_sync({ name = e.pack.name, path = p.path, rev = p.rev }, scanner_cfg)
      if not result then
        table.insert(kept, e) -- aegis missing / failed; fail-open
      else
        local v = result.verdict or "?"
        local blocked = (v == "block") or (strict and v == "prompt")
        if blocked then
          vim.notify(
            ("pakku: BLOCKED %s — verdict=%s risk=%d caps=[%s]%s"):format(
              e.pack.name,
              v,
              result.risk_score or 0,
              table.concat(result.capabilities or {}, ", "),
              result.cached and " (cached)" or ""
            ),
            vim.log.levels.ERROR
          )
          Loader.pending[e.pack.name] = nil
          Loader.by_name[e.pack.name] = nil
        else
          table.insert(kept, e)
          if v == "prompt" then
            vim.notify(
              ("pakku: %s verdict=prompt risk=%d caps=[%s] (allowed by gate=block)"):format(
                e.pack.name,
                result.risk_score or 0,
                table.concat(result.capabilities or {}, ", ")
              ),
              vim.log.levels.WARN
            )
          end
        end
      end
    end
  end
  return kept
end

function M.add(specs)
  ensure_pack()
  local entries = Policy.filter(Spec.normalize(specs), state.config.security)
  if #entries == 0 then return end

  -- Register everything in the loader first; the gate may unregister rejects.
  for _, e in ipairs(entries) do
    Loader.register(e.lazy)
  end

  -- Install all entries to disk without auto-loading. vim.pack.add with
  -- load=false clones + writes lockfile but does NOT :packadd. This lets the
  -- scan gate inspect the on-disk source before activation.
  local all_pack = vim.tbl_map(function(e) return e.pack end, entries)
  local confirm = state.config.confirm_update
  vim.pack.add(all_pack, { load = false, confirm = confirm })

  -- Pre-activation gate (§2.1). Synchronous, cached by (name, rev).
  entries = gate_entries(entries, state.config.scanner)
  if #entries == 0 then return end

  -- Eager: priority sort, then :packadd + apply config. Survivors only.
  local eager = {}
  for _, e in ipairs(entries) do
    if not e.lazy.is_lazy then table.insert(eager, e) end
  end
  table.sort(eager, function(a, b) return (a.lazy.priority or 50) > (b.lazy.priority or 50) end)
  for _, e in ipairs(eager) do
    local ok, err = pcall(vim.cmd, "packadd " .. e.lazy.name)
    if not ok then
      vim.notify(("pakku: packadd %s failed: %s"):format(e.lazy.name, err), vim.log.levels.ERROR)
    else
      Loader.apply(e.lazy)
    end
  end
  -- Lazy survivors stay in Loader.pending; triggers will :packadd them later.
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

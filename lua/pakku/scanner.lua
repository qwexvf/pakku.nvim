-- aegis-cli subprocess wrapper, async.
--
-- Three scan modes, all opt-in via setup() config:
--   analyze  — `aegis analyze --ecosystem neovim <path> --json`
--              Lua AST capability scan. Real signal for Neovim plugins.
--   actions  — `aegis actions scan <path> --json`
--              Detects malicious GH Actions workflows shipped in plugin repos.
--   sbom     — `aegis sbom --local <path> --format cyclonedx --output ...`
--              CycloneDX for plugins carrying Cargo.lock / go.sum / package-lock.
local M = {}

local VERDICT_LEVEL = {
  safe = vim.log.levels.INFO,
  review = vim.log.levels.INFO,
  prompt = vim.log.levels.WARN,
  block = vim.log.levels.ERROR,
}

local function notify_exit(name, label, res)
  local lvl = vim.log.levels.INFO
  if res.code == 1 then
    lvl = vim.log.levels.WARN
  elseif res.code >= 2 then
    lvl = vim.log.levels.ERROR
  end
  local msg = ("pakku scan[%s] %s: exit=%d"):format(name, label, res.code)
  if res.stderr and #res.stderr > 0 and res.code ~= 0 then msg = msg .. "\n" .. res.stderr end
  vim.notify(msg, lvl)
end

local function write_report(report_dir, name, ext, body)
  if not report_dir or not body or body == "" then return end
  vim.fn.mkdir(report_dir, "p")
  local out = vim.fs.joinpath(report_dir, name .. "." .. ext)
  local f = io.open(out, "w")
  if f then
    f:write(body)
    f:close()
  end
end

local function run_analyze(bin, plugin, opts)
  local cmd = { bin, "analyze", "--ecosystem", "neovim", plugin.path, "--json" }
  if opts.evidence then table.insert(cmd, "--evidence") end
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      local ok, data = pcall(vim.json.decode, res.stdout or "")
      if not ok or type(data) ~= "table" then return notify_exit(plugin.name, "analyze", res) end
      write_report(opts.report_dir, plugin.name, "analyze.json", res.stdout)
      local lvl = VERDICT_LEVEL[data.verdict] or vim.log.levels.INFO
      vim.notify(
        ("pakku scan[%s] verdict=%s risk=%d caps=[%s]"):format(
          plugin.name,
          data.verdict or "?",
          data.risk_score or 0,
          table.concat(data.capabilities or {}, ", ")
        ),
        lvl
      )
    end)
  end)
end

local function run_actions(bin, plugin, opts)
  local cmd = { bin, "actions", "scan", plugin.path, "--json" }
  if opts.fail_on then
    table.insert(cmd, "--fail-on")
    table.insert(cmd, opts.fail_on)
  end
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      write_report(opts.report_dir, plugin.name, "actions.json", res.stdout)
      notify_exit(plugin.name, "actions", res)
    end)
  end)
end

local function run_sbom(bin, plugin, opts)
  if not opts.report_dir then return end
  vim.fn.mkdir(opts.report_dir, "p")
  local out = vim.fs.joinpath(opts.report_dir, plugin.name .. ".cdx.json")
  vim.system(
    { bin, "sbom", "--local", plugin.path, "--format", "cyclonedx", "--output", out },
    { text = true },
    function(res)
      vim.schedule(function() notify_exit(plugin.name, "sbom", res) end)
    end
  )
end

function M.scan_one(plugin, opts)
  opts = opts or {}
  local bin = opts.bin or "aegis"
  if vim.fn.executable(bin) ~= 1 then
    return vim.notify(
      ("pakku: aegis binary `%s` not on PATH, skipping scan"):format(bin),
      vim.log.levels.WARN
    )
  end
  opts.report_dir = opts.report_dir or vim.fs.joinpath(vim.fn.stdpath("state"), "pakku", "scans")

  if opts.analyze ~= false then run_analyze(bin, plugin, opts) end
  if opts.actions ~= false then run_actions(bin, plugin, opts) end
  if opts.sbom == true then run_sbom(bin, plugin, opts) end -- opt-in only
end

function M.scan_all(opts)
  local ok, plugins = pcall(vim.pack.get)
  if not ok then return vim.notify("pakku: vim.pack.get() failed", vim.log.levels.ERROR) end
  for _, p in ipairs(plugins) do
    M.scan_one({ name = p.spec.name, path = p.path }, opts or {})
  end
end

-- Synchronous capability scan for use in the install gate (init.lua M.add).
-- Caches by (name, rev) so re-running pakku.add on every nvim launch only
-- pays the aegis cost when the commit SHA changes. Returns a table with:
--   { verdict, risk_score, capabilities, evidence, cached (bool) }
-- or nil if aegis is missing / produced no usable output.
function M.scan_sync(plugin, opts)
  opts = opts or {}
  local bin = opts.bin or "aegis"
  if vim.fn.executable(bin) ~= 1 then return nil end

  local report_dir = opts.report_dir or vim.fs.joinpath(vim.fn.stdpath("state"), "pakku", "scans")
  local rev = (plugin.rev or "unknown"):sub(1, 8)
  local cache_path = vim.fs.joinpath(report_dir, ("%s-%s.cache.json"):format(plugin.name, rev))

  -- Cache hit: read + decode + return.
  local fr = io.open(cache_path, "r")
  if fr then
    local body = fr:read("*a")
    fr:close()
    local ok, data = pcall(vim.json.decode, body)
    if ok and type(data) == "table" then
      data.cached = true
      return data
    end
  end

  -- Cache miss: run aegis synchronously.
  local cmd = { bin, "analyze", "--ecosystem", "neovim", plugin.path, "--json" }
  if opts.evidence then table.insert(cmd, "--evidence") end
  local res = vim.system(cmd, { text = true }):wait()
  if res.code > 1 then return nil end
  local ok, data = pcall(vim.json.decode, res.stdout or "")
  if not ok or type(data) ~= "table" then return nil end

  vim.fn.mkdir(report_dir, "p")
  local fw = io.open(cache_path, "w")
  if fw then
    fw:write(res.stdout)
    fw:close()
  end
  data.cached = false
  return data
end

return M

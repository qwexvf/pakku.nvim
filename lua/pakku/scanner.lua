-- aegis-cli subprocess wrapper, async.
-- aegis cannot AST-scan Lua. We use it for:
--   1. `aegis actions scan <path>` -> finds malicious GH Actions workflows shipped in plugin repos
--   2. `aegis sbom --local <path>` -> CycloneDX inventory for plugins that ship manifest-bearing deps
--      (go.nvim has go.mod, blink.cmp has Cargo workspaces, etc.)
local M = {}

local function ensure_dir(p)
  vim.fn.mkdir(p, "p")
end

local function have_bin(bin)
  return vim.fn.executable(bin) == 1
end

local function notify_findings(name, label, res)
  local lvl = vim.log.levels.INFO
  if res.code == 1 then lvl = vim.log.levels.WARN
  elseif res.code >= 2 then lvl = vim.log.levels.ERROR end
  local msg = ("pakku scan[%s] %s: exit=%d"):format(name, label, res.code)
  if res.stderr and #res.stderr > 0 and res.code ~= 0 then
    msg = msg .. "\n" .. res.stderr
  end
  vim.notify(msg, lvl)
end

local function run_async(cmd, name, label)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function() notify_findings(name, label, res) end)
  end)
end

local function run_actions(bin, path, name, fail_on)
  local cmd = { bin, "actions", "scan", path, "--json" }
  if fail_on then table.insert(cmd, "--fail-on"); table.insert(cmd, fail_on) end
  run_async(cmd, name, "actions")
end

local function run_sbom(bin, path, name, report_dir)
  ensure_dir(report_dir)
  local out = vim.fs.joinpath(report_dir, name .. ".cdx.json")
  run_async({
    bin, "sbom", "--local", path, "--format", "cyclonedx", "--output", out,
  }, name, "sbom")
end

-- Scan a single plugin (async, fire-and-forget).
function M.scan_one(plugin, opts)
  opts = opts or {}
  local bin = opts.bin or "aegis"
  if not have_bin(bin) then
    vim.notify(("pakku: aegis binary `%s` not on PATH, skipping scan"):format(bin), vim.log.levels.WARN)
    return
  end
  local report_dir = opts.report_dir or vim.fs.joinpath(vim.fn.stdpath("state"), "pakku", "scans")
  if opts.actions ~= false then
    run_actions(bin, plugin.path, plugin.name, opts.fail_on)
  end
  if opts.sbom ~= false then
    run_sbom(bin, plugin.path, plugin.name, report_dir)
  end
end

-- Scan all installed plugins concurrently.
function M.scan_all(opts)
  opts = opts or {}
  local ok, plugins = pcall(vim.pack.get)
  if not ok then
    vim.notify("pakku: vim.pack.get() failed", vim.log.levels.ERROR)
    return
  end
  for _, p in ipairs(plugins) do
    M.scan_one({ name = p.spec.name, path = p.path }, opts)
  end
end

return M

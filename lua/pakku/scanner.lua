-- aegis-cli subprocess wrapper, async.
-- aegis does NOT AST-scan Lua. Use cases:
--   `aegis actions scan <path>` — malicious GH Actions workflows in plugin repos
--   `aegis sbom --local <path>`  — CycloneDX inventory for plugins shipping
--                                 Cargo.lock / go.sum / package-lock.json
local M = {}

local function notify(name, label, res)
  local lvl = vim.log.levels.INFO
  if res.code == 1 then lvl = vim.log.levels.WARN
  elseif res.code >= 2 then lvl = vim.log.levels.ERROR end
  local msg = ("pakku scan[%s] %s: exit=%d"):format(name, label, res.code)
  if res.stderr and #res.stderr > 0 and res.code ~= 0 then
    msg = msg .. "\n" .. res.stderr
  end
  vim.notify(msg, lvl)
end

local function run(cmd, name, label)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function() notify(name, label, res) end)
  end)
end

function M.scan_one(plugin, opts)
  opts = opts or {}
  local bin = opts.bin or "aegis"
  if vim.fn.executable(bin) ~= 1 then
    return vim.notify(("pakku: aegis binary `%s` not on PATH, skipping scan"):format(bin),
                      vim.log.levels.WARN)
  end
  local report_dir = opts.report_dir or vim.fs.joinpath(vim.fn.stdpath("state"), "pakku", "scans")

  if opts.actions ~= false then
    local c = { bin, "actions", "scan", plugin.path, "--json" }
    if opts.fail_on then table.insert(c, "--fail-on"); table.insert(c, opts.fail_on) end
    run(c, plugin.name, "actions")
  end

  if opts.sbom ~= false then
    vim.fn.mkdir(report_dir, "p")
    local out = vim.fs.joinpath(report_dir, plugin.name .. ".cdx.json")
    run({ bin, "sbom", "--local", plugin.path, "--format", "cyclonedx", "--output", out },
        plugin.name, "sbom")
  end
end

function M.scan_all(opts)
  local ok, plugins = pcall(vim.pack.get)
  if not ok then return vim.notify("pakku: vim.pack.get() failed", vim.log.levels.ERROR) end
  for _, p in ipairs(plugins) do
    M.scan_one({ name = p.spec.name, path = p.path }, opts or {})
  end
end

return M

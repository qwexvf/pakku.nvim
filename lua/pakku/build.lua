-- PackChanged-driven build runner.
local M = {}

local function err(fmt, ...) vim.notify(("pakku: " .. fmt):format(...), vim.log.levels.ERROR) end

local function run_build(spec, path)
  local b = spec.build
  if type(b) == "function" then
    local ok, e = pcall(b, { path = path, spec = spec })
    if not ok then err("build fn error for %s: %s", spec.name, e) end
    return
  end
  if type(b) ~= "string" then return end
  if b:sub(1, 1) == ":" then
    -- Ex-cmd build (e.g. ":TSUpdate"): need plugin's runtime files sourced
    -- first. packadd + defer so PackChanged unwinds before further vim.cmd.
    vim.schedule(function()
      pcall(vim.cmd, "packadd " .. spec.name)
      local ok, e = pcall(vim.cmd, b:sub(2))
      if not ok then err("build ex-cmd error for %s: %s", spec.name, e) end
    end)
    return
  end
  local res = vim.system({ "sh", "-c", b }, { cwd = path, text = true }):wait()
  if res.code ~= 0 then
    err("build failed for %s (exit %d)\n%s", spec.name, res.code, res.stderr or "")
  end
end

function M.attach(config)
  vim.api.nvim_create_autocmd("PackChanged", {
    group = vim.api.nvim_create_augroup("pakku.build", { clear = true }),
    callback = function(args)
      local d = args.data
      if not d or (d.kind ~= "install" and d.kind ~= "update") then return end
      local name = d.spec and d.spec.name
      if not name then return end
      local spec = require("pakku.loader").by_name[name]
      if spec and spec.build then run_build(spec, d.path) end
      if config and config.scanner and config.scanner.enabled then
        for _, k in ipairs(config.scanner.on or { "install", "update" }) do
          if k == d.kind then
            require("pakku.scanner").scan_one({ name = name, path = d.path }, config.scanner)
            break
          end
        end
      end
    end,
  })
end

return M

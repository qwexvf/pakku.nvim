-- PackChanged-driven build runner
local M = {}

local loader = require("packline.loader")

local function run_shell(cmd, cwd, name)
  local res = vim.system({ "sh", "-c", cmd }, { cwd = cwd, text = true }):wait()
  if res.code ~= 0 then
    vim.notify(
      ("packline: build failed for %s (exit %d)\n%s"):format(name, res.code, res.stderr or ""),
      vim.log.levels.ERROR
    )
  end
end

local function run_build(spec, path)
  local b = spec.build
  if type(b) == "function" then
    local ok, err = pcall(b, { path = path, spec = spec })
    if not ok then
      vim.notify(("packline: build fn error for %s: %s"):format(spec.name, err), vim.log.levels.ERROR)
    end
    return
  end
  if type(b) ~= "string" then return end
  if b:sub(1, 1) == ":" then
    local ok, err = pcall(vim.cmd, b:sub(2))
    if not ok then
      vim.notify(("packline: build ex-cmd error for %s: %s"):format(spec.name, err), vim.log.levels.ERROR)
    end
  else
    run_shell(b, path, spec.name)
  end
end

function M.attach(config)
  vim.api.nvim_create_autocmd("PackChanged", {
    group = vim.api.nvim_create_augroup("packline.build", { clear = true }),
    callback = function(args)
      local d = args.data
      if not d or (d.kind ~= "install" and d.kind ~= "update") then return end
      local name = d.spec and d.spec.name
      if not name then return end
      local spec = loader.by_name[name]
      if spec and spec.build then
        run_build(spec, d.path)
      end
      if config and config.scanner and config.scanner.enabled then
        local on = config.scanner.on or { "install", "update" }
        local matches = false
        for _, k in ipairs(on) do if k == d.kind then matches = true; break end end
        if matches then
          require("packline.scanner").scan_one({ name = name, path = d.path }, config.scanner)
        end
      end
    end,
  })
end

return M

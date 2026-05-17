-- lazy-load triggers + opts/config dispatch
local M = {}

M.pending = {}  -- name -> lazy_spec
M.active = {}   -- name -> true
M.by_name = {}  -- name -> lazy_spec (all specs, for build hook lookup)

local group = vim.api.nvim_create_augroup("packline.loader", { clear = true })

local function call_setup(spec)
  local ok_mod, mod = pcall(require, spec.modname)
  if not ok_mod then
    vim.notify(("packline: require('%s') failed for %s"):format(spec.modname, spec.name), vim.log.levels.WARN)
    return
  end
  if type(mod.setup) ~= "function" then
    vim.notify(("packline: %s has no setup(); pass `config` instead of `opts`"):format(spec.modname), vim.log.levels.WARN)
    return
  end
  local ok, err = pcall(mod.setup, spec.opts)
  if not ok then
    vim.notify(("packline: %s setup error: %s"):format(spec.name, err), vim.log.levels.ERROR)
  end
end

function M.load(name)
  if M.active[name] then return end
  local spec = M.pending[name]
  if not spec then return end
  M.pending[name] = nil
  M.active[name] = true

  local ok, err = pcall(vim.cmd, "packadd " .. name)
  if not ok then
    vim.notify(("packline: packadd %s failed: %s"):format(name, err), vim.log.levels.ERROR)
    return
  end

  if spec.config then
    local cok, cerr = pcall(spec.config)
    if not cok then
      vim.notify(("packline: %s config error: %s"):format(name, cerr), vim.log.levels.ERROR)
    end
  elseif spec.opts ~= nil then
    call_setup(spec)
  end
end

-- For eager (non-lazy) specs that already loaded via vim.pack.
function M.run_eager_config(spec)
  M.active[spec.name] = true
  if spec.config then
    local ok, err = pcall(spec.config)
    if not ok then
      vim.notify(("packline: %s config error: %s"):format(spec.name, err), vim.log.levels.ERROR)
    end
  elseif spec.opts ~= nil then
    call_setup(spec)
  end
end

local function as_list(v)
  if type(v) == "table" then return v end
  return { v }
end

function M.register(spec)
  M.by_name[spec.name] = spec
  if not spec.is_lazy then return false end
  M.pending[spec.name] = spec
  local name = spec.name

  if spec.event then
    vim.api.nvim_create_autocmd(as_list(spec.event), {
      group = group,
      once = true,
      callback = function() M.load(name) end,
    })
  end

  if spec.ft then
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = as_list(spec.ft),
      once = true,
      callback = function() M.load(name) end,
    })
  end

  if spec.cmd then
    for _, c in ipairs(as_list(spec.cmd)) do
      local cmd_name = c
      vim.api.nvim_create_user_command(cmd_name, function(args)
        pcall(vim.api.nvim_del_user_command, cmd_name)
        M.load(name)
        local prefix = ""
        if args.bang then prefix = "!" end
        if args.range == 2 then
          vim.cmd(string.format("%d,%d%s%s %s", args.line1, args.line2, cmd_name, prefix, args.args))
        else
          vim.cmd(string.format("%s%s %s", cmd_name, prefix, args.args))
        end
      end, { nargs = "*", range = true, bang = true, complete = "file" })
    end
  end

  return true
end

return M

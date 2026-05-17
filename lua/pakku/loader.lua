-- lazy-load triggers + opts/config dispatch.
local M = {
  pending = {},  -- name -> lazy_spec (awaiting trigger)
  active  = {},  -- name -> true
  by_name = {},  -- name -> lazy_spec (all specs)
}

local group = vim.api.nvim_create_augroup("pakku.loader", { clear = true })

local function warn(fmt, ...) vim.notify(("pakku: " .. fmt):format(...), vim.log.levels.WARN) end
local function err(fmt, ...)  vim.notify(("pakku: " .. fmt):format(...), vim.log.levels.ERROR) end

local function apply_config(spec)
  if spec.config then
    local ok, e = pcall(spec.config)
    if not ok then err("%s config error: %s", spec.name, e) end
    return
  end
  if spec.opts == nil then return end
  local ok_mod, mod = pcall(require, spec.modname)
  if not ok_mod then return warn("require('%s') failed for %s", spec.modname, spec.name) end
  if type(mod.setup) ~= "function" then
    return warn("%s has no setup(); pass `config` instead of `opts`", spec.modname)
  end
  local ok, e = pcall(mod.setup, spec.opts)
  if not ok then err("%s setup error: %s", spec.name, e) end
end

function M.load(name)
  if M.active[name] then return end
  local spec = M.pending[name]
  if not spec then return end
  M.pending[name] = nil
  M.active[name] = true
  local ok, e = pcall(vim.cmd, "packadd " .. name)
  if not ok then return err("packadd %s failed: %s", name, e) end
  apply_config(spec)
end

function M.apply(spec)  -- eager: vim.pack already packadd'd; just config
  M.active[spec.name] = true
  apply_config(spec)
end

local function as_list(v) return type(v) == "table" and v or { v } end

local function on_event(name, events, pattern, ev)
  vim.api.nvim_create_autocmd(events, {
    group = group, once = true, pattern = pattern,
    callback = function() M.load(name) end,
  })
end

function M.register(spec)
  M.by_name[spec.name] = spec
  if not spec.is_lazy then return false end
  M.pending[spec.name] = spec
  local name = spec.name

  if spec.event then
    local native, virtual = {}, {}
    for _, e in ipairs(as_list(spec.event)) do
      table.insert(e == "VeryLazy" and virtual or native, e)
    end
    if #native > 0  then on_event(name, native, nil) end
    if #virtual > 0 then on_event(name, "User", virtual) end
  end

  if spec.ft then on_event(name, "FileType", as_list(spec.ft)) end

  if spec.cmd then
    for _, c in ipairs(as_list(spec.cmd)) do
      local cmd_name = c
      vim.api.nvim_create_user_command(cmd_name, function(a)
        pcall(vim.api.nvim_del_user_command, cmd_name)
        M.load(name)
        local prefix = a.bang and "!" or ""
        local body = a.args or ""
        if a.range == 2 then
          vim.cmd(("%d,%d%s%s %s"):format(a.line1, a.line2, cmd_name, prefix, body))
        elseif a.range == 1 then
          vim.cmd(("%d%s%s %s"):format(a.line1, cmd_name, prefix, body))
        else
          vim.cmd(("%s%s %s"):format(cmd_name, prefix, body))
        end
      end, { nargs = "*", range = true, bang = true, complete = "file" })
    end
  end
  return true
end

return M

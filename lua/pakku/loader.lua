-- lazy-load triggers + opts/config dispatch.
local M = {
  pending = {}, -- name -> lazy_spec (awaiting trigger)
  active = {}, -- name -> true
  by_name = {}, -- name -> lazy_spec (all specs)
  times = {}, -- name -> { ms = N, kind = "eager"|"lazy" } load timing
}

local _hrtime = (vim.uv or vim.loop).hrtime
local function elapsed_ms(t0) return (_hrtime() - t0) / 1e6 end

local group = vim.api.nvim_create_augroup("pakku.loader", { clear = true })

local function warn(fmt, ...) vim.notify(("pakku: " .. fmt):format(...), vim.log.levels.WARN) end
local function err(fmt, ...) vim.notify(("pakku: " .. fmt):format(...), vim.log.levels.ERROR) end

-- Candidate require() names, in order of preference. Naming convention
-- is inconsistent: nvim-surround keeps prefix, nvim-lspconfig strips it,
-- nvim-web-devicons keeps prefix. We try a few until one yields setup().
local function modname_candidates(spec)
  local list, seen = {}, {}
  local function add(s)
    if s and s ~= "" and not seen[s] then
      seen[s] = true
      table.insert(list, s)
    end
  end
  add(spec.modname) -- inferred (suffix+prefix stripped)
  add(spec.name) -- raw name as-is (nvim-surround style)
  add((spec.name:gsub("%.nvim$", "")):gsub("%-nvim$", "")) -- only suffix stripped
  add((spec.name:gsub("^nvim%-", ""))) -- only prefix stripped
  return list
end

-- forward declarations (defined below, referenced by M.load/M.apply above them)
local normalize_keys, install_keys

local function apply_config(spec)
  if spec.config then
    local ok, e = pcall(spec.config)
    if not ok then err("%s config error: %s", spec.name, e) end
    return
  end
  if spec.opts == nil then return end
  local mod, tried
  for _, n in ipairs(modname_candidates(spec)) do
    tried = (tried and tried .. ", " or "") .. n
    local ok, m = pcall(require, n)
    if ok and type(m) == "table" and type(m.setup) == "function" then
      mod = m
      break
    end
  end
  if not mod then return warn("no setup() for %s (tried: %s)", spec.name, tried or "?") end
  local ok, e = pcall(mod.setup, spec.opts)
  if not ok then err("%s setup error: %s", spec.name, e) end
end

function M.load(name)
  if M.active[name] then return end
  local spec = M.pending[name]
  if not spec then return end
  M.pending[name] = nil
  M.active[name] = true
  local t0 = _hrtime()
  local ok, e = pcall(vim.cmd, "packadd " .. name)
  if not ok then return err("packadd %s failed: %s", name, e) end
  apply_config(spec)
  install_keys(spec)
  M.times[name] = { ms = elapsed_ms(t0), kind = "lazy" }
end

function M.apply(spec) -- eager: vim.pack already packadd'd; just config
  M.active[spec.name] = true
  local t0 = _hrtime()
  apply_config(spec)
  install_keys(spec)
  M.times[spec.name] = { ms = elapsed_ms(t0), kind = "eager" }
end

local function as_list(v) return type(v) == "table" and v or { v } end

local function on_event(name, events, pattern, ev)
  vim.api.nvim_create_autocmd(events, {
    group = group,
    once = true,
    pattern = pattern,
    callback = function() M.load(name) end,
  })
end

-- Normalize lazy.nvim-style `keys` field into list of { lhs, modes, rhs, opts }.
-- Accepts:  "<leader>x"
--           { "<leader>x", "<leader>y" }
--           { { "<leader>x", function() ... end, mode = "n", desc = "..." }, ... }
--           { { "<leader>x", "<cmd>Foo<cr>", desc = "..." }, ... }
function normalize_keys(keys)
  if type(keys) == "string" then return { { lhs = keys, modes = { "n" } } } end
  if type(keys) ~= "table" then return {} end
  local out = {}
  for _, k in ipairs(keys) do
    if type(k) == "string" then
      table.insert(out, { lhs = k, modes = { "n" } })
    elseif type(k) == "table" then
      local lhs = k.lhs or k[1]
      if lhs then
        local m = k.mode
        if m == nil then
          m = { "n" }
        elseif type(m) == "string" then
          m = { m }
        end
        -- rhs is the second positional element (fn or string). The rest of
        -- the table's string keys become keymap opts (desc, silent, expr, ...).
        local rhs = k.rhs or k[2]
        local opts = {}
        for key, val in pairs(k) do
          if type(key) == "string" and key ~= "lhs" and key ~= "rhs" and key ~= "mode" and key ~= "ft" then
            opts[key] = val
          end
        end
        table.insert(out, { lhs = lhs, modes = m, rhs = rhs, opts = opts })
      end
    end
  end
  return out
end

-- Install the real keymaps a `keys` spec declares (rhs + opts). Called after
-- the plugin is loaded so the mapping the user actually pressed does its job.
-- Entries without an rhs are pure lazy-triggers and carry no real mapping.
function install_keys(spec)
  if not spec.keys then return end
  for _, k in ipairs(normalize_keys(spec.keys)) do
    if k.rhs ~= nil then
      local opts = vim.tbl_extend("keep", k.opts or {}, { silent = true })
      for _, mode in ipairs(k.modes) do
        vim.keymap.set(mode, k.lhs, k.rhs, opts)
      end
    end
  end
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
    if #native > 0 then on_event(name, native, nil) end
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

  if spec.keys then
    for _, k in ipairs(normalize_keys(spec.keys)) do
      local lhs, modes = k.lhs, k.modes
      for _, mode in ipairs(modes) do
        vim.keymap.set(mode, lhs, function()
          -- Remove shim from every mode before re-feeding so the plugin's
          -- real keymap (installed by apply_config) handles the keypress.
          for _, m in ipairs(modes) do
            pcall(vim.keymap.del, m, lhs)
          end
          M.load(name)
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "m", false)
        end, { silent = true, desc = "pakku-lazy: " .. name })
      end
    end
  end

  return true
end

return M

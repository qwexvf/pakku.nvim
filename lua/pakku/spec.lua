-- spec normalization + dep flattening for pakku.
-- Accepts pakku-native specs AND lazy.nvim shorthand:
--   "owner/repo"                       -> src = https://github.com/owner/repo
--   { "owner/repo", ... }              -> shorthand at index 1
--   { src = "...", ... }               -> full URL
--   { import = "module.or.dir" }       -> walk runtimepath dir or require()
-- Duplicate names merge (later wins for scalars; event/ft/cmd append; src/name pinned to first).
local M = {}

local GITHUB = "https://github.com/"

local function looks_like_shorthand(s)
  return type(s) == "string" and not s:find("://") and s:match("^[%w._-]+/[%w._-]+$") ~= nil
end

local function infer_name(src, explicit)
  if explicit then return explicit end
  return ((src:match("([^/]+)$") or src):gsub("%.git$", ""))
end

local function infer_modname(name, explicit)
  if explicit then return explicit end
  return name:gsub("%.nvim$", ""):gsub("%.lua$", ""):gsub("%.vim$", "")
             :gsub("^nvim%-", ""):gsub("%-nvim$", "")
end

-- vim.pack accepts tag/branch/sha strings or vim.version.range(...) output.
-- Coerce "*"/"^x"/">=x" into a range; pass tag-looking strings through.
local function coerce_version(v)
  if type(v) ~= "string" then return v end
  if v == "*" or v:match("^[%^~<>=]") then return vim.version.range(v) end
  return v
end

local function coerce(raw)
  if type(raw) == "string" then
    return { src = looks_like_shorthand(raw) and (GITHUB .. raw) or raw }
  end
  if type(raw) ~= "table" then error("pakku: spec must be string or table") end
  if raw[1] and type(raw[1]) == "string" and not raw.src then
    raw = vim.deepcopy(raw)
    raw.src = looks_like_shorthand(raw[1]) and (GITHUB .. raw[1]) or raw[1]
    raw[1] = nil
  end
  return raw
end

local function coerce_deps(deps)
  if deps == nil then return nil end
  if type(deps) == "string" then return { coerce(deps) } end
  local out = {}
  for _, d in ipairs(deps) do table.insert(out, coerce(d)) end
  return out
end

local function split(raw)
  local pack_spec = {
    src = raw.src,
    name = infer_name(raw.src, raw.name),
    version = coerce_version(raw.version),
    data = raw.data,
  }
  local lazy_spec = {
    name = pack_spec.name,
    modname = infer_modname(pack_spec.name, raw.modname),
    opts = raw.opts, config = raw.config, build = raw.build,
    event = raw.event, ft = raw.ft, cmd = raw.cmd,
    priority = raw.priority,
  }
  lazy_spec.is_lazy = (raw.event ~= nil) or (raw.ft ~= nil) or (raw.cmd ~= nil)
  return pack_spec, lazy_spec
end

-- Wrap a require() return into a list of specs. Single specs detected by
-- shorthand at [1] or explicit src; otherwise treat as a list.
local function as_speclist(mod)
  if type(mod) ~= "table" then return {} end
  if type(mod[1]) == "string" or mod.src then return { mod } end
  return mod
end

-- Resolve `{ import = "x.y" }` to a directory in runtimepath. Returns dir or nil.
local function find_import_dir(modpath)
  local rel = "lua/" .. modpath:gsub("%.", "/") .. "/"
  return (vim.api.nvim_get_runtime_file(rel, false))[1]
end

local function walk_import_dir(modpath, dir)
  local out = {}
  local init_ok, init_mod = pcall(require, modpath)
  if init_ok then
    for _, sub in ipairs(as_speclist(init_mod)) do table.insert(out, sub) end
  end
  local files = vim.fn.glob(dir .. "*.lua", false, true)
  table.sort(files)
  for _, f in ipairs(files) do
    local base = vim.fn.fnamemodify(f, ":t:r")
    if base ~= "init" then
      local ok, mod = pcall(require, modpath .. "." .. base)
      if ok then
        for _, sub in ipairs(as_speclist(mod)) do table.insert(out, sub) end
      end
    end
  end
  return out
end

local function expand_imports(specs)
  local out = {}
  for _, raw in ipairs(specs) do
    if type(raw) == "table" and raw.import then
      local dir = find_import_dir(raw.import)
      local imported
      if dir then
        imported = walk_import_dir(raw.import, dir)
      else
        local ok, mod = pcall(require, raw.import)
        if not ok then error(("pakku: import '%s' failed: %s"):format(raw.import, mod)) end
        imported = as_speclist(mod)
      end
      for _, sub in ipairs(expand_imports(imported)) do table.insert(out, sub) end
    else
      table.insert(out, raw)
    end
  end
  return out
end

-- Append-with-dedup helper for event/ft/cmd lists.
local function add_list(target, field, val)
  if val == nil then return end
  local cur = target[field]
  cur = (cur == nil) and {} or (type(cur) == "table" and cur or { cur })
  for _, v in ipairs(type(val) == "table" and val or { val }) do
    local has = false
    for _, e in ipairs(cur) do if e == v then has = true break end end
    if not has then table.insert(cur, v) end
  end
  target[field] = cur
end

-- Merge later-occurrence fields into the first entry. src/name pinned to first.
local function merge_into(existing, later)
  local p, l = existing.pack, existing.lazy
  if later.version ~= nil then p.version = coerce_version(later.version) end
  if later.data ~= nil then p.data = later.data end
  if later.opts ~= nil then
    l.opts = (type(l.opts) == "table" and type(later.opts) == "table")
      and vim.tbl_deep_extend("force", l.opts, later.opts) or later.opts
  end
  for _, k in ipairs({ "config", "build", "modname", "priority" }) do
    if later[k] ~= nil then l[k] = later[k] end
  end
  add_list(l, "event", later.event)
  add_list(l, "ft",    later.ft)
  add_list(l, "cmd",   later.cmd)
  l.is_lazy = (l.event ~= nil) or (l.ft ~= nil) or (l.cmd ~= nil)
end

-- Flatten + dedupe. Returns ordered { pack, lazy } entries; deps emitted before
-- dependents.
function M.normalize(specs)
  local out, seen = {}, {}
  local function visit(raw)
    raw = coerce(raw)
    if not raw.src then return end
    local name = infer_name(raw.src, raw.name)
    if seen[name] then
      merge_into(out[seen[name]], raw)
      return
    end
    local deps = coerce_deps(raw.dependencies)
    if deps then for _, d in ipairs(deps) do visit(d) end end
    local pack_spec, lazy_spec = split(raw)
    table.insert(out, { pack = pack_spec, lazy = lazy_spec })
    seen[name] = #out
  end
  for _, raw in ipairs(expand_imports(specs)) do visit(raw) end
  return out
end

return M

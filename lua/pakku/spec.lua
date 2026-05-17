-- spec normalization + dep flattening for pakku.
--
-- Accepts both pakku-native specs and lazy.nvim-style shorthand:
--   - "owner/repo"             string positional -> src = "https://github.com/owner/repo"
--   - { "owner/repo", ... }    table with index 1 = shorthand
--   - { src = "...", ... }     full URL spec
--   - { import = "module" }    lazy.nvim import directive -> require(module), recurse
--
-- Compat fields tolerated (mapped or ignored):
--   - lazy = false             ignored (no triggers => eager by default)
--   - priority = N             retained in lazy_spec; init.lua sorts eager specs by it
--   - dependencies = "x/y"     coerced to { { src = ... } }
--   - dependencies = { "x/y" } each element coerced
local M = {}

local GITHUB = "https://github.com/"

local function looks_like_shorthand(s)
  if type(s) ~= "string" then return false end
  if s:find("://") then return false end
  return s:match("^[%w._-]+/[%w._-]+$") ~= nil
end

local function shorthand_to_src(s)
  return GITHUB .. s
end

local function infer_name(src, explicit)
  if explicit then return explicit end
  local last = src:match("([^/]+)$") or src
  return (last:gsub("%.git$", ""))
end

local function infer_modname(name, explicit)
  if explicit then return explicit end
  local m = name:gsub("%.nvim$", ""):gsub("%.lua$", ""):gsub("%.vim$", "")
  m = m:gsub("^nvim%-", ""):gsub("%-nvim$", "")
  return m
end

-- Coerce any single spec input into a table with `src`.
local function coerce(raw)
  if type(raw) == "string" then
    if looks_like_shorthand(raw) then
      return { src = shorthand_to_src(raw) }
    end
    return { src = raw }  -- assume full URL
  end
  if type(raw) ~= "table" then
    error("pakku: spec must be string or table, got " .. type(raw))
  end
  -- table with index 1 set to a shorthand string (lazy.nvim convention)
  if raw[1] and type(raw[1]) == "string" and not raw.src then
    raw = vim.deepcopy(raw)
    raw.src = looks_like_shorthand(raw[1]) and shorthand_to_src(raw[1]) or raw[1]
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

-- vim.pack accepts: tag/branch/sha strings OR vim.version.range() output.
-- lazy.nvim users write `version = "*"` or `version = "^1"` as string.
-- Coerce semver-range strings into vim.version.range; pass tag-looking strings through.
local function coerce_version(v)
  if v == nil or type(v) ~= "string" then return v end
  if v == "*" or v:match("^[%^~]") or v:match("^[<>=]") then
    return vim.version.range(v)
  end
  return v  -- tag, branch, or sha; vim.pack handles literally
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
    opts = raw.opts,
    config = raw.config,
    build = raw.build,
    event = raw.event,
    ft = raw.ft,
    cmd = raw.cmd,
    priority = raw.priority,
  }
  lazy_spec.is_lazy = (raw.event ~= nil) or (raw.ft ~= nil) or (raw.cmd ~= nil)
  return pack_spec, lazy_spec
end

-- Wrap a module's return into a list of specs.
-- A file may return either a single spec ({ "x/y", opts={} } or { src=..., }) or a
-- list of specs ({ { ... }, { ... } }). Lazy.nvim accepts both; pakku does too.
local function as_speclist(mod)
  if type(mod) ~= "table" then return {} end
  if type(mod[1]) == "string" then return { mod } end  -- single spec, shorthand at [1]
  if mod.src then return { mod } end                    -- single spec, explicit src
  return mod                                            -- already a list
end

-- For `{ import = "plugins.lsp" }`: resolve to a runtimepath dir, then walk
-- every `<dir>/*.lua` (skip the dir's own `init.lua` IF it returned content via
-- the explicit require below; lazy.nvim treats init.lua specially: its return
-- is included once).
local function find_import_dir(modpath)
  local rel = "lua/" .. modpath:gsub("%.", "/") .. "/"
  local dirs = vim.api.nvim_get_runtime_file(rel, false)
  return dirs[1]
end

local function walk_import_dir(modpath, dir)
  local out = {}
  -- Try init.lua first (if present) to keep author-ordered preludes.
  local init_ok, init_mod = pcall(require, modpath)
  if init_ok and type(init_mod) == "table" then
    for _, sub in ipairs(as_speclist(init_mod)) do table.insert(out, sub) end
  end
  local files = vim.fn.glob(dir .. "*.lua", false, true)
  table.sort(files)
  for _, f in ipairs(files) do
    local base = vim.fn.fnamemodify(f, ":t:r")
    if base ~= "init" then
      local sub_ok, sub_mod = pcall(require, modpath .. "." .. base)
      if sub_ok and type(sub_mod) == "table" then
        for _, sub in ipairs(as_speclist(sub_mod)) do table.insert(out, sub) end
      end
    end
  end
  return out
end

-- Expand `{ import = "module.path" }` directives. Two resolution paths:
-- 1. If module path resolves to a directory in runtimepath, walk it
--    (lazy.nvim parity for "import = directory of spec files").
-- 2. Otherwise require() the module and treat its return as a spec list.
local function expand_imports(specs)
  local out = {}
  for _, raw in ipairs(specs) do
    if type(raw) == "table" and raw.import then
      local imported
      local dir = find_import_dir(raw.import)
      if dir then
        imported = walk_import_dir(raw.import, dir)
      else
        local ok, mod = pcall(require, raw.import)
        if not ok then
          error(("pakku: import '%s' failed: %s"):format(raw.import, mod))
        end
        imported = as_speclist(mod)
      end
      for _, sub in ipairs(expand_imports(imported)) do table.insert(out, sub) end
    else
      table.insert(out, raw)
    end
  end
  return out
end

-- Flatten dependencies depth-first, dep before dependent.
-- Returns ordered list of { pack_spec, lazy_spec } entries.
function M.normalize(specs)
  local out = {}
  local seen = {}

  local function visit(raw)
    raw = coerce(raw)
    if not raw.src then return end  -- pure-import or stripped node; skip
    local name = infer_name(raw.src, raw.name)
    if seen[name] then
      vim.notify(("pakku: duplicate spec for %s, keeping first"):format(name), vim.log.levels.WARN)
      return
    end
    seen[name] = true

    local deps = coerce_deps(raw.dependencies)
    if deps then
      for _, dep in ipairs(deps) do visit(dep) end
    end

    local pack_spec, lazy_spec = split(raw)
    table.insert(out, { pack = pack_spec, lazy = lazy_spec })
  end

  for _, raw in ipairs(expand_imports(specs)) do visit(raw) end
  return out
end

return M

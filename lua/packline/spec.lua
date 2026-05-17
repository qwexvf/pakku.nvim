-- spec normalization + dep flattening for packline
local M = {}

local LAZY_FIELDS = { event = true, ft = true, cmd = true }
local PACKLINE_FIELDS = {
  event = true, ft = true, cmd = true,
  opts = true, config = true, build = true,
  dependencies = true, modname = true,
}

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

local function split(raw)
  local pack_spec = {
    src = raw.src,
    name = infer_name(raw.src, raw.name),
    version = raw.version,
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
  }
  lazy_spec.is_lazy = (raw.event ~= nil) or (raw.ft ~= nil) or (raw.cmd ~= nil)
  return pack_spec, lazy_spec
end

-- Flatten dependencies depth-first, dep before dependent.
-- Returns ordered list of { pack_spec, lazy_spec } entries.
function M.normalize(specs)
  local out = {}
  local seen = {}

  local function visit(raw)
    if type(raw) == "string" then raw = { src = raw } end
    assert(raw.src, "packline: spec missing `src`")
    local name = infer_name(raw.src, raw.name)
    if seen[name] then return end
    seen[name] = true

    if raw.dependencies then
      for _, dep in ipairs(raw.dependencies) do visit(dep) end
    end

    local pack_spec, lazy_spec = split(raw)
    table.insert(out, { pack = pack_spec, lazy = lazy_spec })
  end

  for _, raw in ipairs(specs) do visit(raw) end
  return out
end

return M

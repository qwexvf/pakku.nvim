-- Security policy on plugin specs. Runs before vim.pack.add(); rejects drop.
local M = {}

-- Extract host from git URL. Returns host, scheme.
function M.host_of(src)
  if not src then return nil end
  local scheme, host = src:match("^(%w+)://([^/]+)")
  if scheme then return host, scheme end
  local ssh = src:match("^git@([^:]+):")
  if ssh then return ssh, "ssh" end
  return nil, nil
end

function M.check(pack_spec, cfg)
  local host, scheme = M.host_of(pack_spec.src)
  if not host then return false, "unparseable src: " .. (pack_spec.src or "?") end

  if cfg.require_https and scheme and scheme ~= "https" and scheme ~= "ssh" then
    return false, ("non-https scheme %q for %s"):format(scheme, pack_spec.src)
  end

  if cfg.allowlist and #cfg.allowlist > 0 then
    local ok = false
    for _, h in ipairs(cfg.allowlist) do if host == h then ok = true break end end
    if not ok then return false, ("host %q not in allowlist"):format(host) end
  end

  if cfg.require_pinned_version and pack_spec.version == nil then
    return true, ("unpinned: %s tracks default branch"):format(pack_spec.name)
  end

  return true, nil
end

function M.filter(entries, cfg)
  local kept = {}
  for _, e in ipairs(entries) do
    local ok, reason = M.check(e.pack, cfg)
    if not ok then
      vim.notify("pakku policy: rejected " .. (reason or "?"), vim.log.levels.ERROR)
    else
      if reason then vim.notify("pakku policy: " .. reason, vim.log.levels.WARN) end
      table.insert(kept, e)
    end
  end
  return kept
end

return M

-- Security policy checks on plugin specs.
-- Runs before vim.pack.add() — disallowed specs are dropped with notify.
local M = {}

-- Extract host from git URL.
-- Accepts:  https://github.com/u/r(.git)?  |  http://...  |  git://...  |  git@host:u/r
function M.host_of(src)
  if not src then return nil end
  local scheme, host = src:match("^(%w+)://([^/]+)")
  if scheme then return host, scheme end
  local ssh_host = src:match("^git@([^:]+):")
  if ssh_host then return ssh_host, "ssh" end
  return nil, nil
end

-- Returns ok, reason
function M.check(pack_spec, cfg)
  local src = pack_spec.src
  local host, scheme = M.host_of(src)

  if not host then
    return false, ("unparseable src: %s"):format(src)
  end

  if cfg.require_https and scheme and scheme ~= "https" and scheme ~= "ssh" then
    return false, ("non-https scheme %q for %s"):format(scheme, src)
  end

  if cfg.allowlist and #cfg.allowlist > 0 then
    local allowed = false
    for _, h in ipairs(cfg.allowlist) do
      if host == h then allowed = true; break end
    end
    if not allowed then
      return false, ("host %q not in allowlist"):format(host)
    end
  end

  if cfg.require_pinned_version and (pack_spec.version == nil) then
    -- Warn, do not block. Tracking default branch is risky but common.
    return true, ("unpinned: %s tracks default branch"):format(pack_spec.name)
  end

  return true, nil
end

-- Filter a list of normalized entries. Returns kept list; emits notify for dropped.
function M.filter(entries, cfg)
  local kept = {}
  for _, entry in ipairs(entries) do
    local ok, reason = M.check(entry.pack, cfg)
    if not ok then
      vim.notify("pakku policy: rejected " .. (reason or "?"), vim.log.levels.ERROR)
    else
      if reason then
        vim.notify("pakku policy: " .. reason, vim.log.levels.WARN)
      end
      table.insert(kept, entry)
    end
  end
  return kept
end

return M

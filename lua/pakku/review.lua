-- Pre-flight update audit: fetch each plugin (no apply), inspect range,
-- flag tamper signals. Render report to scratch buffer.
--
-- Checks (v1):
--   1. force-push  -> current HEAD not ancestor of fetched target
--   2. tag drift   -> spec.version is a tag string and tag SHA != target
--                     (catches "maintainer moved v1.0 to a new commit")
--
-- New-contributor detection deferred (needs persisted author state).
local M = {}

local function git(args, cwd)
  local res = vim.system({ "git", "-C", cwd, unpack(args) }, { text = true }):wait()
  return res.code, (res.stdout or ""):gsub("\n$", ""), (res.stderr or "")
end

local function fetch(path)
  local code, _, err = git({ "fetch", "--quiet", "origin" }, path)
  return code == 0, err
end

local function rev_parse(path, ref)
  local code, out = git({ "rev-parse", ref }, path)
  if code ~= 0 then return nil end
  return out
end

local function default_branch_target(path)
  -- origin/HEAD symbolic-ref points at the default branch on the remote.
  local code, out = git({ "rev-parse", "--abbrev-ref", "origin/HEAD" }, path)
  if code ~= 0 then return nil end
  return rev_parse(path, out)
end

local function is_ancestor(path, anc, desc)
  local code = git({ "merge-base", "--is-ancestor", anc, desc }, path)
  return code == 0
end

local function log_range(path, old, new)
  local code, out = git({
    "log", "--pretty=format:%h %an │ %s", "--no-merges", old .. ".." .. new,
  }, path)
  if code ~= 0 or out == "" then return {} end
  return vim.split(out, "\n", { trimempty = true })
end

local function compute_target(plug)
  local v = plug.spec and plug.spec.version
  if type(v) == "string" then
    -- Try interpreting as tag/branch/sha. If it resolves, prefer that.
    local sha = rev_parse(plug.path, v)
    if sha then return sha, "version=" .. v end
  end
  -- Otherwise: default branch tip after fetch.
  local sha = default_branch_target(plug.path)
  if sha then return sha, "origin/HEAD" end
  return nil, "unresolved"
end

local function review_one(plug)
  local entry = { name = plug.spec.name, path = plug.path, findings = {}, log = {} }
  local ok, err = fetch(plug.path)
  if not ok then
    table.insert(entry.findings, "FETCH FAILED: " .. err)
    return entry
  end

  local head = plug.rev or rev_parse(plug.path, "HEAD")
  local target, target_label = compute_target(plug)
  entry.head, entry.target, entry.target_label = head, target, target_label

  if not target then
    table.insert(entry.findings, "TARGET UNRESOLVED: " .. (target_label or "?"))
    return entry
  end

  if head == target then
    entry.up_to_date = true
    return entry
  end

  if not is_ancestor(plug.path, head, target) then
    table.insert(entry.findings, "FORCE-PUSH: HEAD not ancestor of " .. target_label
      .. " (history rewritten upstream)")
  end

  if type(plug.spec.version) == "string" then
    local tag_sha = rev_parse(plug.path, "refs/tags/" .. plug.spec.version)
    if tag_sha and tag_sha ~= target then
      table.insert(entry.findings,
        ("TAG DRIFT: pinned tag %s points at %s, fetch target is %s"):format(
          plug.spec.version, tag_sha:sub(1, 8), target:sub(1, 8)))
    end
  end

  entry.log = log_range(plug.path, head, target)
  return entry
end

local function push(lines, s)
  if not s then return end
  for _, part in ipairs(vim.split(tostring(s), "\n", { plain = true })) do
    table.insert(lines, part)
  end
end

local function render(entries)
  local lines = {}
  push(lines, "pakku review — " .. os.date("%Y-%m-%d %H:%M:%S"))
  push(lines, "")
  local total_findings = 0
  for _, e in ipairs(entries) do
    if e.up_to_date then
      push(lines, ("✓ %s  up-to-date  %s"):format(e.name, (e.head or ""):sub(1, 8)))
    else
      push(lines, ("● %s  %s → %s  (%s)"):format(
        e.name, (e.head or "?"):sub(1, 8), (e.target or "?"):sub(1, 8), e.target_label or "?"))
      for _, f in ipairs(e.findings) do
        push(lines, "    ! " .. f)
        total_findings = total_findings + 1
      end
      for _, line in ipairs(e.log) do
        push(lines, "      " .. line)
      end
    end
    push(lines, "")
  end
  table.insert(lines, 1, ("Findings: %d across %d plugins"):format(total_findings, #entries))
  table.insert(lines, 2, "")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "pakku-review"

  local w = math.floor(vim.o.columns * 0.85)
  local h = math.floor(vim.o.lines * 0.8)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w, height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    border = "rounded",
    title = " pakku review ", title_pos = "center",
    style = "minimal",
  })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
  return total_findings
end

function M.review(names)
  if not vim.pack then
    vim.notify("pakku: vim.pack missing", vim.log.levels.ERROR)
    return
  end
  local plugins = vim.pack.get(names)
  if #plugins == 0 then
    vim.notify("pakku: no plugins to review", vim.log.levels.WARN)
    return
  end

  vim.notify(("pakku: fetching %d plugins (no apply)..."):format(#plugins))
  local entries = {}
  for _, p in ipairs(plugins) do
    table.insert(entries, review_one(p))
  end
  local n = render(entries)
  if n > 0 then
    vim.notify(("pakku review: %d finding(s) — see floating buffer"):format(n), vim.log.levels.WARN)
  end
end

return M

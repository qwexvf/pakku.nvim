-- Pre-flight update audit: fetch each plugin (no apply), inspect range,
-- flag tamper signals. Render report to floating buffer.
-- v1 checks:
--   force-push  — HEAD not ancestor of fetched target (history rewritten)
--   tag drift   — spec.version is a tag string and tag's SHA != fetch target
local M = {}

local function git(args, cwd)
  local r = vim.system({ "git", "-C", cwd, unpack(args) }, { text = true }):wait()
  return r.code, (r.stdout or ""):gsub("\n$", ""), (r.stderr or "")
end

local function rev_parse(path, ref)
  local code, out = git({ "rev-parse", ref }, path)
  return code == 0 and out or nil
end

-- Returns target_sha, label, opt_warning.
local function compute_target(plug)
  local v = plug.spec and plug.spec.version
  if type(v) == "string" then
    local sha = rev_parse(plug.path, v)
    if sha then return sha, "version=" .. v end
    -- Pinned version exists but doesn't resolve locally; signal explicitly.
    local fallback_warn = ("VERSION UNRESOLVED: pinned %q not found locally, falling back to origin/HEAD"):format(v)
    local code, branch = git({ "rev-parse", "--abbrev-ref", "origin/HEAD" }, plug.path)
    if code ~= 0 then return nil, "origin/HEAD", fallback_warn end
    return rev_parse(plug.path, branch), "origin/HEAD", fallback_warn
  end
  local code, branch = git({ "rev-parse", "--abbrev-ref", "origin/HEAD" }, plug.path)
  if code ~= 0 then return nil, "origin/HEAD" end
  return rev_parse(plug.path, branch), "origin/HEAD"
end

local function review_one(plug)
  local e = { name = plug.spec.name, path = plug.path, findings = {}, log = {} }
  local code, _, ferr = git({ "fetch", "--quiet", "origin" }, plug.path)
  if code ~= 0 then
    table.insert(e.findings, "FETCH-FAILED: " .. ferr)
    return e
  end

  local head = plug.rev or rev_parse(plug.path, "HEAD")
  local target, label, vwarn = compute_target(plug)
  e.head, e.target, e.target_label = head, target, label
  if vwarn then table.insert(e.findings, vwarn) end

  if not target then
    table.insert(e.findings, "TARGET UNRESOLVED: " .. (label or "?"))
    return e
  end
  if head == target then e.up_to_date = true; return e end

  local anc_code = (vim.system({ "git", "-C", plug.path, "merge-base", "--is-ancestor", head, target }, { text = true }):wait()).code
  if anc_code ~= 0 then
    table.insert(e.findings, ("FORCE-PUSH: HEAD not ancestor of %s (history rewritten upstream)"):format(label))
  end

  if type(plug.spec.version) == "string" then
    local tag_sha = rev_parse(plug.path, "refs/tags/" .. plug.spec.version)
    if tag_sha and tag_sha ~= target then
      table.insert(e.findings, ("TAG DRIFT: pinned tag %s points at %s, fetch target is %s"):format(
        plug.spec.version, tag_sha:sub(1, 8), target:sub(1, 8)))
    end
  end

  local lc, lout = git({ "log", "--pretty=format:%h %an │ %s", "--no-merges", head .. ".." .. target }, plug.path)
  if lc == 0 and lout ~= "" then e.log = vim.split(lout, "\n", { trimempty = true }) end
  return e
end

local function push(lines, s)
  if not s then return end
  for _, p in ipairs(vim.split(tostring(s), "\n", { plain = true })) do
    table.insert(lines, p)
  end
end

local function render(entries)
  local lines = {}
  push(lines, "pakku review — " .. os.date("%Y-%m-%d %H:%M:%S"))
  push(lines, "")
  local total = 0
  for _, e in ipairs(entries) do
    if e.up_to_date then
      push(lines, ("✓ %s  up-to-date  %s"):format(e.name, (e.head or ""):sub(1, 8)))
    else
      push(lines, ("● %s  %s → %s  (%s)"):format(
        e.name, (e.head or "?"):sub(1, 8), (e.target or "?"):sub(1, 8), e.target_label or "?"))
      for _, f in ipairs(e.findings) do
        push(lines, "    ! " .. f)
        total = total + 1
      end
      for _, l in ipairs(e.log) do push(lines, "      " .. l) end
    end
    push(lines, "")
  end
  table.insert(lines, 1, ("Findings: %d across %d plugins"):format(total, #entries))
  table.insert(lines, 2, "")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "pakku-review"

  local w = math.floor(vim.o.columns * 0.85)
  local h = math.floor(vim.o.lines * 0.8)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = w, height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    border = "rounded", title = " pakku review ", title_pos = "center", style = "minimal",
  })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
  return total
end

function M.review(names)
  if not vim.pack then return vim.notify("pakku: vim.pack missing", vim.log.levels.ERROR) end
  local plugins = vim.pack.get(names)
  if #plugins == 0 then return vim.notify("pakku: no plugins to review", vim.log.levels.WARN) end

  vim.notify(("pakku: fetching %d plugins (no apply)..."):format(#plugins))
  local entries = {}
  for _, p in ipairs(plugins) do table.insert(entries, review_one(p)) end
  local n = render(entries)
  if n > 0 then
    vim.notify(("pakku review: %d finding(s) — see floating buffer"):format(n), vim.log.levels.WARN)
  end
end

return M

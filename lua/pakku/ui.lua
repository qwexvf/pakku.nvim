-- pakku floating UI — dashboard with sections, expandable rows, live refresh.
-- Cursor actions: u single, U all, v single review, V all review, x single clean.
local M = {}

local TABS = { "Home", "Update", "Clean", "Log" }
local ICONS = {
  active = "●",
  pending = "○",
  unmanaged = "·",
  expanded = "▼",
  collapsed = "▶",
}
local SECTIONS = {
  { name = "Loaded", key = "active", hl = "PakkuActive" },
  { name = "Pending", key = "pending", hl = "PakkuPending" },
  { name = "Unmanaged", key = "unmanaged", hl = "PakkuUnmanaged" },
}

local state = {
  buf = nil,
  win = nil,
  width = 80,
  tab = "Home",
  expanded = {},
  row_map = {},
  status = nil, -- one-line status message (e.g. "updating 3/26")
}
local ns = vim.api.nvim_create_namespace("pakku.ui")

local function host_of(src)
  return src and (src:match("^https?://([^/]+)") or src:match("^git@([^:]+):")) or "?"
end

local function get_plugins()
  if not vim.pack then return {} end
  local plugins = vim.pack.get()
  table.sort(plugins, function(a, b) return a.spec.name < b.spec.name end)
  local L = require("pakku.loader")
  for _, p in ipairs(plugins) do
    p._st = L.active[p.spec.name] and "active"
      or L.pending[p.spec.name] and "pending"
      or "unmanaged"
    p._lazy = L.by_name[p.spec.name]
  end
  return plugins
end

local function counts(plugins)
  local c = { active = 0, pending = 0, unmanaged = 0 }
  for _, p in ipairs(plugins) do
    c[p._st] = (c[p._st] or 0) + 1
  end
  return c
end

local function render_home(plugins)
  local lines, hl, row_map = {}, {}, {}
  local function emit(line, group)
    table.insert(lines, line)
    if group then table.insert(hl, { row = #lines, group = group }) end
    return #lines
  end

  local rule = string.rep("─", state.width - 2)
  local first_section = true

  for _, sec in ipairs(SECTIONS) do
    local matches = vim.tbl_filter(function(p) return p._st == sec.key end, plugins)
    if #matches > 0 then
      if not first_section then emit("") end
      first_section = false
      emit(("  %s %s   %d"):format(ICONS[sec.key], sec.name, #matches), sec.hl)
      emit("  " .. rule, "PakkuDetail")
      for _, p in ipairs(matches) do
        local exp = state.expanded[p.spec.name] and ICONS.expanded or ICONS.collapsed
        local rev = (p.rev or ""):sub(1, 8)
        local row =
          emit(("  %s %-30s  %s  %s"):format(exp, p.spec.name, rev, host_of(p.spec.src)), sec.hl)
        row_map[row] = p.spec.name

        if state.expanded[p.spec.name] then
          local lz = p._lazy or {}
          local function detail(k, v) emit(("        %-9s %s"):format(k, v), "PakkuDetail") end
          detail("src", p.spec.src or "?")
          detail("rev", p.rev or "?")
          if p.spec.version then detail("version", tostring(p.spec.version)) end
          if lz.event then detail("event", vim.inspect(lz.event)) end
          if lz.ft then detail("ft", vim.inspect(lz.ft)) end
          if lz.cmd then detail("cmd", vim.inspect(lz.cmd)) end
          if lz.keys then detail("keys", vim.inspect(lz.keys)) end
          if lz.build then detail("build", tostring(lz.build)) end
          if lz.priority then detail("priority", tostring(lz.priority)) end
        end
      end
    end
  end
  if #plugins == 0 then emit("  (no plugins managed)", "PakkuDetail") end
  return lines, hl, row_map
end

local function header_line(plugins)
  local c = counts(plugins)
  local total = c.active + c.pending + c.unmanaged
  return ("  %d total   %d loaded   %d pending"):format(total, c.active, c.pending)
end

local function tab_strip()
  local parts = {}
  for _, t in ipairs(TABS) do
    table.insert(parts, t == state.tab and ("[" .. t .. "]") or (" " .. t .. " "))
  end
  return "  " .. table.concat(parts, " ")
end

local function render_lines()
  local lines, hl, row_map = {}, {}, {}
  local plugins = get_plugins()
  local rule = string.rep("─", state.width - 2)

  table.insert(lines, tab_strip())
  table.insert(hl, { row = #lines, group = "PakkuTabs" })
  table.insert(lines, "")
  table.insert(lines, header_line(plugins))
  table.insert(hl, { row = #lines, group = "PakkuHeader" })
  table.insert(lines, "  " .. rule)
  table.insert(hl, { row = #lines, group = "PakkuDetail" })
  table.insert(lines, "")

  local body, body_hl, body_rows
  if state.tab == "Home" then
    body, body_hl, body_rows = render_home(plugins)
  else
    body = {
      "",
      "  " .. state.tab .. " tab — use :Pakku " .. state.tab:lower() .. " from CLI",
      "",
    }
    body_hl, body_rows = {}, {}
  end

  local offset = #lines
  for _, l in ipairs(body) do
    table.insert(lines, l)
  end
  for _, h in ipairs(body_hl) do
    table.insert(hl, { row = h.row + offset, group = h.group })
  end
  for r, n in pairs(body_rows) do
    row_map[r + offset] = n
  end

  if state.status then
    table.insert(lines, "")
    table.insert(lines, "  " .. state.status)
    table.insert(hl, { row = #lines, group = "PakkuHeader" })
  end
  return lines, hl, row_map
end

local function refresh()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    state.width = vim.api.nvim_win_get_width(state.win)
  end
  local lines, hl, row_map = render_lines()
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  state.row_map = row_map
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, h in ipairs(hl) do
    vim.api.nvim_buf_set_extmark(
      state.buf,
      ns,
      h.row - 1,
      0,
      { end_line = h.row, hl_group = h.group }
    )
  end
end

local function at_cursor()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return nil end
  return state.row_map[vim.api.nvim_win_get_cursor(state.win)[1]]
end

local function cycle(delta)
  for i, t in ipairs(TABS) do
    if t == state.tab then
      state.tab = TABS[((i - 1 + delta) % #TABS) + 1]
      return refresh()
    end
  end
end

local function set_status(msg)
  state.status = msg
  refresh()
end

-- Async update. vim.pack.update is internally blocking on git fetch, but we
-- wrap in vim.schedule + confirm=false so the UI redraws first and avoids the
-- confirm buffer. PackChanged callbacks live-refresh per plugin.
local function update_all()
  set_status("updating all plugins…")
  vim.schedule(function()
    local ok, err = pcall(function() vim.pack.update(nil, { confirm = false }) end)
    if not ok then
      set_status("update failed: " .. tostring(err))
    else
      set_status(nil)
    end
  end)
end

local function update_one(name)
  set_status("updating " .. name .. "…")
  vim.schedule(function()
    local ok, err = pcall(function() vim.pack.update({ name }, { confirm = false }) end)
    if not ok then
      set_status("update failed: " .. tostring(err))
    else
      set_status(nil)
    end
  end)
end

local function setup_hl()
  local function defhl(n, a)
    if vim.fn.hlexists(n) == 0 then vim.api.nvim_set_hl(0, n, a) end
  end
  defhl("PakkuActive", { link = "DiagnosticOk" })
  defhl("PakkuPending", { link = "DiagnosticHint" })
  defhl("PakkuUnmanaged", { link = "Comment" })
  defhl("PakkuSection", { link = "Title" })
  defhl("PakkuDetail", { link = "Comment" })
  defhl("PakkuTabs", { link = "Statement" })
  defhl("PakkuHeader", { link = "Title" })
end

local function setup_keys(buf)
  local function map(k, fn, desc)
    vim.keymap.set(
      "n",
      k,
      fn,
      { buffer = buf, nowait = true, silent = true, desc = "pakku: " .. desc }
    )
  end
  map("q", function() M.close() end, "close")
  map("R", refresh, "refresh")
  map("<CR>", function()
    local n = at_cursor()
    if n then
      state.expanded[n] = not state.expanded[n]
      refresh()
    end
  end, "toggle detail")

  -- u: single update; U: update all (async, no blocking confirm buffer).
  map("u", function()
    local n = at_cursor()
    if n then update_one(n) end
  end, "update under cursor")
  map("U", update_all, "update all async")

  map("v", function()
    local n = at_cursor()
    if n then require("pakku").review({ n }) end
  end, "review under cursor")
  map("V", function() require("pakku").review(nil) end, "review all")

  map("x", function()
    local n = at_cursor()
    if not n then return end
    vim.ui.select({ "Yes", "No" }, { prompt = "Clean " .. n .. "?" }, function(c)
      if c == "Yes" then
        require("pakku").clean({ n })
        refresh()
      end
    end)
  end, "clean under cursor")

  map("L", function() cycle(1) end, "next tab")
  map("H", function() cycle(-1) end, "prev tab")
  map("?", function() M.help() end, "help")
end

function M.open()
  setup_hl()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    refresh()
    return
  end
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].buftype = "nofile"
    vim.bo[state.buf].bufhidden = "wipe"
    vim.bo[state.buf].filetype = "pakku"
    setup_keys(state.buf)
  end
  local w, h = math.floor(vim.o.columns * 0.9), math.floor(vim.o.lines * 0.85)
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    border = "rounded",
    title = " pakku  ? for keys ",
    title_pos = "center",
    style = "minimal",
  })
  vim.wo[state.win].cursorline = true
  vim.wo[state.win].wrap = false
  vim.wo[state.win].signcolumn = "no"
  refresh()
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win, state.buf, state.status = nil, nil, nil
end

function M.help()
  vim.notify(table.concat({
    "pakku keymaps",
    "",
    "  q        close",
    "  R        refresh",
    "  <CR>     toggle plugin detail",
    "  u  / U   update under cursor / update ALL (async)",
    "  v  / V   review under cursor / review ALL",
    "  x        clean under cursor",
    "  H / L    previous / next tab",
    "  ?        this help",
  }, "\n"))
end

vim.api.nvim_create_autocmd("PackChanged", {
  group = vim.api.nvim_create_augroup("pakku.ui.live", { clear = true }),
  callback = function()
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then vim.schedule(refresh) end
  end,
})

return M

-- pakku floating UI — lazy.nvim-parity dashboard.
-- Home tab: Loaded / Pending / Unmanaged sections, expandable rows.
-- Cursor actions: U update, V review, X clean. R refresh. <CR> toggle detail.
-- Update/Clean/Log tabs reserved (use :Pakku <cmd> from CLI for now).
local M = {}

local TABS  = { "Home", "Update", "Clean", "Log" }
local ICONS = { active = "●", pending = "○", unmanaged = "·",
                expanded = "▼", collapsed = "▶" }
local SECTIONS = {
  { name = "Loaded",    key = "active",    hl = "PakkuActive"    },
  { name = "Pending",   key = "pending",   hl = "PakkuPending"   },
  { name = "Unmanaged", key = "unmanaged", hl = "PakkuUnmanaged" },
}

local state = { buf = nil, win = nil, tab = "Home", expanded = {}, row_map = {} }
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

local function render_home(plugins)
  local lines, hl, row_map = {}, {}, {}
  local function emit(line, group)
    table.insert(lines, line)
    if group then table.insert(hl, { row = #lines, group = group }) end
    return #lines
  end

  for _, sec in ipairs(SECTIONS) do
    local matches = vim.tbl_filter(function(p) return p._st == sec.key end, plugins)
    if #matches > 0 then
      emit(("── %s (%d)"):format(sec.name, #matches), "PakkuSection")
      for _, p in ipairs(matches) do
        local exp = state.expanded[p.spec.name] and ICONS.expanded or ICONS.collapsed
        local row = emit(("  %s %s  %-28s %-10s %s"):format(
          exp, ICONS[sec.key], p.spec.name, (p.rev or ""):sub(1, 8), host_of(p.spec.src)),
          sec.hl)
        row_map[row] = p.spec.name

        if state.expanded[p.spec.name] then
          local lz = p._lazy or {}
          local function detail(k, v) emit(("      %-9s %s"):format(k .. ":", v), "PakkuDetail") end
          detail("src", p.spec.src or "?")
          detail("rev", p.rev or "?")
          if p.spec.version then detail("version", tostring(p.spec.version)) end
          if lz.event then detail("event", vim.inspect(lz.event)) end
          if lz.ft    then detail("ft",    vim.inspect(lz.ft))    end
          if lz.cmd   then detail("cmd",   vim.inspect(lz.cmd))   end
          if lz.build then detail("build", tostring(lz.build))    end
          if lz.priority then detail("priority", tostring(lz.priority)) end
        end
      end
      emit("")
    end
  end
  if #plugins == 0 then emit("  (no plugins managed)", "PakkuDetail") end
  return lines, hl, row_map
end

local function render_lines()
  local lines, hl, row_map = {}, {}, {}

  -- Tab strip
  local parts = {}
  for _, t in ipairs(TABS) do
    table.insert(parts, t == state.tab and ("[" .. t .. "]") or (" " .. t .. " "))
  end
  table.insert(lines, "  " .. table.concat(parts, "  "))
  table.insert(hl, { row = #lines, group = "PakkuTabs" })
  table.insert(lines, string.rep("─", 80))
  table.insert(lines, "")

  local body, body_hl, body_rows
  if state.tab == "Home" then
    body, body_hl, body_rows = render_home(get_plugins())
  else
    body = { "", "  " .. state.tab .. " tab — use :Pakku " .. state.tab:lower() .. " from CLI", "" }
    body_hl, body_rows = {}, {}
  end
  local offset = #lines
  for _, l in ipairs(body) do table.insert(lines, l) end
  for _, h in ipairs(body_hl) do table.insert(hl, { row = h.row + offset, group = h.group }) end
  for r, n in pairs(body_rows) do row_map[r + offset] = n end
  return lines, hl, row_map
end

local function refresh()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  local lines, hl, row_map = render_lines()
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  state.row_map = row_map
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, h in ipairs(hl) do
    vim.api.nvim_buf_set_extmark(state.buf, ns, h.row - 1, 0, { end_line = h.row, hl_group = h.group })
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

local function setup_hl()
  local function defhl(n, a) if vim.fn.hlexists(n) == 0 then vim.api.nvim_set_hl(0, n, a) end end
  defhl("PakkuActive",    { link = "DiagnosticOk" })
  defhl("PakkuPending",   { link = "DiagnosticHint" })
  defhl("PakkuUnmanaged", { link = "Comment" })
  defhl("PakkuSection",   { link = "Title" })
  defhl("PakkuDetail",    { link = "Comment" })
  defhl("PakkuTabs",      { link = "Statement" })
end

local function setup_keys(buf)
  local function map(k, fn, desc)
    vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true, desc = "pakku: " .. desc })
  end
  map("q", function() M.close() end, "close")
  map("R", refresh, "refresh")
  map("<CR>", function()
    local n = at_cursor()
    if n then state.expanded[n] = not state.expanded[n]; refresh() end
  end, "toggle detail")
  map("U", function() local n = at_cursor(); if n then require("pakku").update({ n }) end end, "update")
  map("V", function() local n = at_cursor(); if n then require("pakku").review({ n }) end end, "review")
  map("X", function()
    local n = at_cursor(); if not n then return end
    vim.ui.select({ "Yes", "No" }, { prompt = "Clean " .. n .. "?" }, function(c)
      if c == "Yes" then require("pakku").clean({ n }); refresh() end
    end)
  end, "clean")
  map("L", function() cycle(1) end, "next tab")
  map("H", function() cycle(-1) end, "prev tab")
  map("?", function() M.help() end, "help")
end

function M.open()
  setup_hl()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win); refresh(); return
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
    relative = "editor", width = w, height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    border = "rounded", title = " pakku  (? for help) ", title_pos = "center", style = "minimal",
  })
  vim.wo[state.win].cursorline = true
  vim.wo[state.win].wrap = false
  refresh()
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win, state.buf = nil, nil
end

function M.help()
  vim.notify(table.concat({
    "pakku keymaps", "",
    "  q        close",
    "  R        refresh",
    "  <CR>     toggle plugin detail",
    "  U        update under cursor",
    "  V        review under cursor (audit incoming diff)",
    "  X        clean under cursor",
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

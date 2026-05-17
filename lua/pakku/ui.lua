-- pakku floating UI — lazy.nvim-parity surface.
-- v1 scope:
--   - Tab strip: Home | Update | Clean | Log
--   - Sections (Home tab): Loaded / Pending / Unmanaged with counts
--   - Expandable rows: <CR> toggles per-plugin detail (src, rev, version, triggers, build, priority)
--   - Cursor actions: U=update, V=review, X=clean, R=refresh
--   - Live refresh via PackChanged autocmd
--   - Help overlay (?)
-- Deferred: progress bar during install, diff inline view, profile tab.

local M = {}

local Loader = nil  -- lazy-required; avoid circular

local TABS = { "Home", "Update", "Clean", "Log" }
local ICONS = {
  active     = "●",
  pending    = "○",
  unmanaged  = "·",
  expanded   = "▼",
  collapsed  = "▶",
}

local state = {
  buf = nil,
  win = nil,
  tab = "Home",
  expanded = {},   -- plugin_name -> bool
  row_map = {},    -- buf line index -> plugin_name
}

local ns = vim.api.nvim_create_namespace("pakku.ui")

local function get_loader()
  Loader = Loader or require("pakku.loader")
  return Loader
end

local function host_of(src)
  if not src then return "?" end
  return src:match("^https?://([^/]+)") or src:match("^git@([^:]+):") or "?"
end

local function get_plugins()
  if not vim.pack then return {} end
  local plugins = vim.pack.get()
  table.sort(plugins, function(a, b) return a.spec.name < b.spec.name end)
  local L = get_loader()
  for _, p in ipairs(plugins) do
    if L.active[p.spec.name] then p._st = "active"
    elseif L.pending[p.spec.name] then p._st = "pending"
    else p._st = "unmanaged" end
    p._lazy = L.by_name[p.spec.name]
  end
  return plugins
end

-- One line per atomic render unit. Used to track highlights per-row.
local function render_home(plugins)
  local lines, hl, row_map = {}, {}, {}

  local function emit(line, group)
    table.insert(lines, line)
    if group then table.insert(hl, { row = #lines, group = group }) end
    return #lines
  end

  local sections = {
    { name = "Loaded",    key = "active",    hl = "PakkuActive"    },
    { name = "Pending",   key = "pending",   hl = "PakkuPending"   },
    { name = "Unmanaged", key = "unmanaged", hl = "PakkuUnmanaged" },
  }

  for _, sec in ipairs(sections) do
    local matches = {}
    for _, p in ipairs(plugins) do
      if p._st == sec.key then table.insert(matches, p) end
    end
    if #matches > 0 then
      emit(("── %s (%d)"):format(sec.name, #matches), "PakkuSection")
      for _, p in ipairs(matches) do
        local exp = state.expanded[p.spec.name] and ICONS.expanded or ICONS.collapsed
        local icon = ICONS[sec.key]
        local rev = (p.rev or ""):sub(1, 8)
        local line = ("  %s %s  %-28s %-10s %s"):format(
          exp, icon, p.spec.name, rev, host_of(p.spec.src))
        local row = emit(line, sec.hl)
        row_map[row] = p.spec.name

        if state.expanded[p.spec.name] then
          local lz = p._lazy or {}
          emit("      src:      " .. (p.spec.src or "?"), "PakkuDetail")
          emit("      rev:      " .. (p.rev or "?"), "PakkuDetail")
          if p.spec.version then
            emit("      version:  " .. tostring(p.spec.version), "PakkuDetail")
          end
          if lz.event then emit("      event:    " .. vim.inspect(lz.event), "PakkuDetail") end
          if lz.ft    then emit("      ft:       " .. vim.inspect(lz.ft),    "PakkuDetail") end
          if lz.cmd   then emit("      cmd:      " .. vim.inspect(lz.cmd),   "PakkuDetail") end
          if lz.build then emit("      build:    " .. tostring(lz.build),    "PakkuDetail") end
          if lz.priority then emit("      priority: " .. tostring(lz.priority), "PakkuDetail") end
        end
      end
      emit("")
    end
  end

  if #plugins == 0 then
    emit("  (no plugins managed)", "PakkuDetail")
  end

  return lines, hl, row_map
end

local function render_placeholder(label)
  return {
    "",
    "  " .. label .. " tab — not yet implemented",
    "",
    "  Use :Pakku " .. label:lower() .. " from the command line.",
  }, {}, {}
end

local function render_lines()
  -- Tab strip.
  local lines, hl, row_map = {}, {}, {}
  local tab_parts = {}
  for _, t in ipairs(TABS) do
    if t == state.tab then
      table.insert(tab_parts, "[" .. t .. "]")
    else
      table.insert(tab_parts, " " .. t .. " ")
    end
  end
  table.insert(lines, "  " .. table.concat(tab_parts, "  "))
  table.insert(hl, { row = #lines, group = "PakkuTabs" })
  table.insert(lines, string.rep("─", 80))
  table.insert(lines, "")

  local body_lines, body_hl, body_rows
  if state.tab == "Home" then
    body_lines, body_hl, body_rows = render_home(get_plugins())
  else
    body_lines, body_hl, body_rows = render_placeholder(state.tab)
  end
  local offset = #lines
  for _, l in ipairs(body_lines) do table.insert(lines, l) end
  for _, h in ipairs(body_hl) do
    table.insert(hl, { row = h.row + offset, group = h.group })
  end
  for row, name in pairs(body_rows) do row_map[row + offset] = name end

  return lines, hl, row_map
end

local function apply_highlights(buf, hl)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hl) do
    vim.api.nvim_buf_set_extmark(buf, ns, h.row - 1, 0, {
      end_line = h.row, hl_group = h.group, hl_eol = false,
    })
  end
end

local function refresh()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  local lines, hl, row_map = render_lines()
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  state.row_map = row_map
  apply_highlights(state.buf, hl)
end

local function plugin_at_cursor()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return nil end
  local row = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.row_map and state.row_map[row]
end

local function cycle_tab(delta)
  for i, t in ipairs(TABS) do
    if t == state.tab then
      state.tab = TABS[((i - 1 + delta) % #TABS) + 1]
      refresh()
      return
    end
  end
end

local function setup_default_highlights()
  -- Only set if user hasn't already defined them.
  local function defhl(name, attrs)
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, attrs)
    end
  end
  defhl("PakkuActive",    { link = "DiagnosticOk" })
  defhl("PakkuPending",   { link = "DiagnosticHint" })
  defhl("PakkuUnmanaged", { link = "Comment" })
  defhl("PakkuSection",   { link = "Title" })
  defhl("PakkuDetail",    { link = "Comment" })
  defhl("PakkuTabs",      { link = "Statement" })
end

local function setup_keys(buf)
  local function map(k, fn, desc)
    vim.keymap.set("n", k, fn,
      { buffer = buf, nowait = true, silent = true, desc = "pakku: " .. desc })
  end
  map("q", function() M.close() end, "close")
  map("R", refresh, "refresh")
  map("<CR>", function()
    local name = plugin_at_cursor()
    if name then
      state.expanded[name] = not state.expanded[name]
      refresh()
    end
  end, "toggle details")
  map("U", function()
    local name = plugin_at_cursor()
    if name then require("pakku").update({ name }) end
  end, "update under cursor")
  map("V", function()
    local name = plugin_at_cursor()
    if name then require("pakku").review({ name }) end
  end, "review under cursor")
  map("X", function()
    local name = plugin_at_cursor()
    if not name then return end
    vim.ui.select({ "Yes", "No" }, { prompt = "Clean " .. name .. "?" },
      function(c)
        if c == "Yes" then
          require("pakku").clean({ name })
          refresh()
        end
      end)
  end, "clean under cursor")
  map("L", function() cycle_tab(1) end, "next tab")
  map("H", function() cycle_tab(-1) end, "prev tab")
  map("?", function() M.help() end, "help")
end

local function open_win()
  local w = math.floor(vim.o.columns * 0.9)
  local h = math.floor(vim.o.lines * 0.85)
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = w, height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    border = "rounded",
    title = " pakku  (? for help) ",
    title_pos = "center",
    style = "minimal",
  })
  vim.wo[state.win].cursorline = true
  vim.wo[state.win].wrap = false
end

function M.open()
  setup_default_highlights()
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
  open_win()
  refresh()
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
end

function M.help()
  local lines = {
    "pakku keymaps",
    "",
    "  q        close",
    "  R        refresh",
    "  <CR>     toggle plugin details",
    "  U        update plugin under cursor",
    "  V        review plugin under cursor (audit incoming diff)",
    "  X        clean plugin under cursor",
    "  H / L    previous / next tab",
    "  ?        this help",
  }
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- Hot refresh on install/update/delete so progress is visible.
vim.api.nvim_create_autocmd("PackChanged", {
  group = vim.api.nvim_create_augroup("pakku.ui.live", { clear = true }),
  callback = function()
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      vim.schedule(refresh)
    end
  end,
})

return M

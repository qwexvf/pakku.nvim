-- :Pakku profile — per-plugin load time chart.
-- Times captured in loader.lua. Eager = config/setup time; lazy = packadd +
-- config/setup time when trigger fired. Plugins not yet loaded show as pending.
local M = {}

local function rows()
  local L = require("pakku.loader")
  local out = {}
  for name, t in pairs(L.times) do
    table.insert(out, { name = name, ms = t.ms, kind = t.kind, state = "loaded" })
  end
  for name, _ in pairs(L.pending) do
    if not L.times[name] then
      table.insert(out, { name = name, ms = nil, kind = "lazy", state = "pending" })
    end
  end
  table.sort(out, function(a, b)
    if a.ms and not b.ms then return true end
    if b.ms and not a.ms then return false end
    if a.ms and b.ms then return a.ms > b.ms end
    return a.name < b.name
  end)
  return out
end

function M.show()
  local data = rows()
  local lines = { "pakku startup profile", "" }
  local total, n_loaded, n_pending = 0, 0, 0

  for _, r in ipairs(data) do
    if r.ms then
      total = total + r.ms
      n_loaded = n_loaded + 1
      local bar = string.rep("█", math.min(40, math.floor(r.ms)))
      table.insert(lines, ("  %7.2f ms  [%-5s]  %-30s  %s"):format(
        r.ms, r.kind, r.name, bar))
    else
      n_pending = n_pending + 1
      table.insert(lines, ("  %7s     [%-5s]  %-30s  (not yet triggered)"):format(
        "—", r.kind, r.name))
    end
  end

  table.insert(lines, "")
  table.insert(lines, ("  loaded: %d  pending: %d  total config time: %.2f ms"):format(
    n_loaded, n_pending, total))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "pakku-profile"

  local w = math.floor(vim.o.columns * 0.85)
  local h = math.floor(vim.o.lines * 0.8)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = w, height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    border = "rounded", title = " pakku profile  (q to close) ",
    title_pos = "center", style = "minimal",
  })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
end

return M

local M = {}

function M.check()
  local h = vim.health
  h.start("packline")

  local v = vim.version()
  if v.major == 0 and v.minor < 12 then
    h.error(("Neovim 0.12+ required (current %d.%d.%d)"):format(v.major, v.minor, v.patch))
  else
    h.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
  end

  if vim.pack then
    h.ok("vim.pack present")
  else
    h.error("vim.pack missing")
  end

  local lockfile = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")
  if vim.uv.fs_stat(lockfile) then
    h.ok("lockfile: " .. lockfile)
  else
    h.warn("lockfile not yet present at " .. lockfile)
  end

  local pkl = package.loaded["packline"]
  local cfg = pkl and pkl._state and pkl._state.config or nil
  if not cfg then
    h.warn("packline.setup() not called yet")
    return
  end

  if cfg.scanner.enabled then
    local bin = cfg.scanner.bin or "aegis"
    if vim.fn.executable(bin) == 1 then
      h.ok("aegis-cli on PATH: " .. bin)
      local res = vim.system({ bin, "--version" }, { text = true }):wait()
      if res.code == 0 then
        h.info("aegis version: " .. (res.stdout or ""):gsub("\n$", ""))
      end
    else
      h.warn(("scanner enabled but `%s` not on PATH"):format(bin))
    end
    if vim.fn.isdirectory(cfg.scanner.report_dir) == 1 then
      h.ok("report dir: " .. cfg.scanner.report_dir)
    else
      h.info("report dir (will be created on first scan): " .. cfg.scanner.report_dir)
    end
  else
    h.info("scanner disabled (set scanner.enabled = true to use aegis-cli)")
  end
end

return M

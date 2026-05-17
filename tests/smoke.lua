-- Pakku smoke test: spec normalization, policy gate, loader registry, UI render,
-- profile module, scanner module, keys lazy-trigger. No network, no real plugins.
vim.opt.runtimepath:prepend(".")
vim.notify = function() end

local Spec = require("pakku.spec")
local Loader = require("pakku.loader")
local Policy = require("pakku.policy")
local Pkk = require("pakku")

-- shorthand
local n = Spec.normalize({ "folke/lazydev.nvim" })
assert(#n == 1 and n[1].pack.src == "https://github.com/folke/lazydev.nvim")

-- version coercion
n = Spec.normalize({ { src = "https://github.com/foo/bar", version = "*" } })
assert(type(n[1].pack.version) == "table", "version='*' should coerce")

-- dep flatten + dup merge
n = Spec.normalize({
  { "ray-x/go.nvim", dependencies = { "ray-x/guihua.lua" } },
  { "ray-x/guihua.lua", build = "cd lua/fzy && make" },
})
local by = {}
for _, e in ipairs(n) do
  by[e.pack.name] = e
end
assert(by["guihua.lua"].lazy.build == "cd lua/fzy && make", "dup merge lost build")

-- keys marks lazy
n = Spec.normalize({ { "user/foo", keys = "<leader>x" } })
assert(n[1].lazy.is_lazy == true)

-- policy
local h, s = Policy.host_of("https://github.com/foo/bar")
assert(h == "github.com" and s == "https")
local ok = Policy.check({ src = "git://evil/x", name = "x" }, {
  allowlist = { "github.com" },
  require_https = true,
})
assert(not ok, "git:// should reject")

-- setup
Pkk.setup({})
local cmds = vim.api.nvim_get_commands({})
assert(cmds.Pakku ~= nil)
assert(vim.loader.enabled == true)

-- loader registry
Loader.register({ name = "alpha", is_lazy = false })
Loader.register({ name = "beta", is_lazy = true, event = "BufReadPost" })
assert(Loader.by_name.alpha and Loader.by_name.beta)
assert(Loader.pending.beta and not Loader.pending.alpha)

-- profile
Loader.times["alpha"] = { ms = 1.0, kind = "eager" }
require("pakku.profile").show()
local pbuf
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "pakku-profile" then
    pbuf = b
    break
  end
end
assert(pbuf, "profile buffer missing")

-- UI render
local UI = require("pakku.ui")
vim.pack.get = function()
  return {
    {
      spec = { name = "alpha", src = "https://github.com/foo/alpha" },
      rev = "abcd1234",
      path = "/tmp/a",
    },
  }
end
Loader.active.alpha = true -- so it lands in the "Loaded" section
UI.open()
local ubuf
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "pakku" then
    ubuf = b
    break
  end
end
assert(ubuf, "ui buffer missing")
local body = table.concat(vim.api.nvim_buf_get_lines(ubuf, 0, -1, false), "\n")
assert(body:match("alpha") and body:match("Loaded"), "ui content missing")
UI.close()

-- scanner module surface
local Scanner = require("pakku.scanner")
assert(type(Scanner.scan_one) == "function" and type(Scanner.scan_all) == "function")
assert(type(Scanner.scan_sync) == "function")

-- scan_sync graceful when aegis missing
local r = Scanner.scan_sync(
  { name = "x", path = "/nonexistent", rev = "deadbeef" },
  { bin = "/no/such/bin" }
)
assert(r == nil, "scan_sync should return nil when bin missing")

print("OK: all smoke tests passed")
vim.cmd("qa!")

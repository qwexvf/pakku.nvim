# packline.nvim

Performance- and security-focused plugin manager built on Neovim 0.12's
`vim.pack`.

`vim.pack` ships installs, updates, lockfile (`nvim-pack-lock.json`), semver,
and `PackChanged` events. packline adds the missing pieces on top:

**DX layer**
- lazy-load triggers (event/ft/cmd)
- build hooks (`PackChanged` → shell or ex-cmd)
- dependency ordering
- `opts → require(modname).setup(opts)` sugar

**Performance**
- `vim.loader` (bytecode cache) auto-enabled on setup — ~10–30 ms cold-start win per plugin
- lazy specs never `:packadd` until their trigger fires
- single-pass spec normalization with topological sort

**Security**
- source allowlist — default reject anything outside `github.com`, `codeberg.org`,
  `gitlab.com`, `git.sr.ht`
- HTTPS-only by default (rejects `http://` and `git://` URLs)
- optional unpinned-version warning (flags specs tracking default branch)
- optional supply-chain scanning via
  [aegis-cli](https://github.com/qwexvf/aegis-cli)
  for GitHub Actions workflows + manifest-bearing transitive deps

## Status

Pre-release. Single user (me). API may break.

## Requirements

- Neovim 0.12+
- (optional) `aegis` on PATH for scanning

## Install

```lua
-- in init.lua
vim.pack.add({ { src = "https://github.com/qwexvf/packline.nvim" } })

require("packline").setup({
  performance = {
    loader = true,                -- vim.loader.enable()
  },
  security = {
    allowlist = { "github.com", "codeberg.org" },
    require_https = true,
    require_pinned_version = false,  -- set true to warn on default-branch specs
  },
  scanner = {
    enabled = true,               -- run aegis on install/update
    fail_on = "block",            -- safe | review | prompt | block
  },
})

require("packline").add({
  -- eager: loaded at startup
  { src = "https://github.com/echasnovski/mini.icons", opts = {} },

  -- lazy by filetype
  { src = "https://github.com/folke/lazydev.nvim", ft = "lua", opts = {} },

  -- lazy by command
  { src = "https://github.com/stevearc/oil.nvim", cmd = "Oil", opts = {} },

  -- lazy by event, with build step + deps
  {
    src = "https://github.com/nvim-treesitter/nvim-treesitter",
    version = vim.version.range("^0.10"),
    event = { "BufReadPost", "BufNewFile" },
    build = ":TSUpdate",
    dependencies = {
      { src = "https://github.com/nvim-lua/plenary.nvim" },
    },
    opts = { highlight = { enable = true } },
  },
})
```

## Spec format

Superset of `vim.pack`'s spec:

| Field          | Type                              | Notes |
|----------------|-----------------------------------|-------|
| `src`          | string (required)                 | Git URL. |
| `name`         | string                            | Defaults to repo basename. |
| `version`      | string \| `vim.version.range(…)`  | Branch, tag, commit, or semver range. |
| `modname`      | string                            | Module passed to `require()` for `opts`. Inferred from `name` (strips `nvim-`/`-nvim`/`.nvim`). |
| `opts`         | table                             | Passed to `require(modname).setup(opts)`. |
| `config`       | function                          | Called instead of `opts` if both present. |
| `build`        | string \| function                | `:TSUpdate` (ex-cmd) \| `"make"` (shell) \| `fn(ctx)`. |
| `event`        | string \| string[]                | Lazy-load on autocmd. |
| `ft`           | string \| string[]                | Lazy-load on FileType. |
| `cmd`          | string \| string[]                | Lazy-load on user command (shim auto-installed). |
| `dependencies` | spec[]                            | Installed and loaded before this plugin. |

## Commands

| Command | Description |
|---------|-------------|
| `:Packline status`           | List installed plugins + active/pending state. |
| `:Packline update [name]`    | Forward to `vim.pack.update`. |
| `:Packline clean <name>`     | Forward to `vim.pack.del`. |
| `:Packline scan [name]`      | Run aegis-cli over one or all plugins. |

`:checkhealth packline` reports environment.

## Security model

packline enforces three policies *before* `vim.pack.add()` ever runs:

1. **Host allowlist** — `src` host must be in `security.allowlist`. Default list
   covers the four major forges; empty list disables the check.
2. **HTTPS-only** — `git://` and `http://` schemes are rejected. SSH (`git@host:`)
   is permitted (assumes user manages keys).
3. **Unpinned warning** — opt-in via `security.require_pinned_version = true`.
   Emits a WARN for any spec with no `version` field (default-branch tracking is
   a supply-chain risk: maintainer compromise → next update pulls malicious HEAD).

Rejected specs are dropped with `vim.notify(ERROR)` before any network or
filesystem activity.

## Scanner

When `scanner.enabled = true`, packline runs two aegis-cli subcommands per
install/update event:

1. `aegis actions scan <path>` — flags malicious GitHub Actions workflows
   shipped inside the plugin repo.
2. `aegis sbom --local <path>` — emits a CycloneDX SBOM to
   `stdpath('state')/packline/scans/<name>.cdx.json`. Plugins that bundle
   manifest-bearing deps (e.g. `go.nvim` has `go.mod`, `blink.cmp` has Cargo
   workspaces) get real CVE coverage via aegis's lockfile parsers.

### Honest limitation

aegis-cli does **not** AST-scan Lua. Pure-Lua plugins get an SBOM with no
dependency rows and no capability findings. **Review Lua plugin source
yourself.** packline's scanner catches:

- malicious GH Actions workflows in any plugin repo;
- vulnerable transitive deps in plugins that ship a `Cargo.lock`, `go.sum`,
  `package-lock.json`, etc.

It does not catch a backdoored `lua/foo.lua`. No tool advertised here does.

## Lockfile

packline does not write a lockfile. `vim.pack` writes
`$XDG_CONFIG_HOME/nvim/nvim-pack-lock.json`. Commit it to your dotfiles.

## License

MIT.

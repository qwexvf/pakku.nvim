# packline.nvim

A thin DX layer over Neovim 0.12's built-in `vim.pack`.

`vim.pack` already gives you installs, updates, a lockfile (`nvim-pack-lock.json`),
semver via `vim.version.range`, and `PackChanged` events. What it doesn't give you:
lazy-load triggers, build steps, dependency ordering, or the `opts → setup()` sugar
that makes lazy.nvim pleasant.

packline adds exactly those four things — and nothing else — plus optional
supply-chain scanning via [aegis-cli](https://github.com/qwexvf/aegis-cli).

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
  scanner = {
    enabled = true,        -- run aegis on install/update
    fail_on = "block",     -- safe | review | prompt | block
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

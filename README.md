# pakku.nvim

Performance- and security-focused plugin manager built on Neovim 0.12's
`vim.pack`.

`vim.pack` ships installs, updates, lockfile (`nvim-pack-lock.json`), semver,
and `PackChanged` events. pakku adds the missing pieces on top:

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
vim.pack.add({ { src = "https://github.com/qwexvf/pakku.nvim" } })

require("pakku").setup({
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

require("pakku").add({
  -- eager: loaded at startup
  { src = "https://github.com/echasnovski/mini.icons", opts = {} },

  -- lazy by filetype
  { src = "https://github.com/folke/lazydev.nvim", ft = "lua", opts = {} },

  -- lazy by command
  { src = "https://github.com/stevearc/oil.nvim", cmd = "Oil", opts = {} },

  -- lazy by keypress (lazy.nvim parity)
  { src = "https://github.com/folke/trouble.nvim",
    keys = { { "<leader>xx", mode = "n", desc = "Trouble" } },
    opts = {} },

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
| `event`        | string \| string[]                | Lazy-load on autocmd. `VeryLazy` fires post-`VimEnter`. |
| `ft`           | string \| string[]                | Lazy-load on FileType. |
| `keys`         | string \| string[] \| spec[]      | Lazy-load on first keypress. Spec: `{ "<lhs>", mode = "n"\|{...}, desc = "..." }`. |
| `cmd`          | string \| string[]                | Lazy-load on user command (shim auto-installed). |
| `dependencies` | spec[]                            | Installed and loaded before this plugin. |

## Commands

| Command | Description |
|---------|-------------|
| `:Pakku` / `:Pakku ui`    | Open the floating dashboard (sections, cursor-action keys, live refresh). |
| `:Pakku status`           | Plain-text fleet summary via `vim.notify` (no UI). |
| `:Pakku update [name]`    | Forward to `vim.pack.update`. |
| `:Pakku review [name]`    | Fetch without applying; audit incoming diff for force-pushes + tag drift. Renders report in floating buffer. Press `q` to close. |
| `:Pakku profile`          | Per-plugin load time chart (eager + lazy) in a floating buffer. |
| `:Pakku clean <name>`     | Forward to `vim.pack.del`. |
| `:Pakku scan [name]`      | Run aegis-cli over one or all plugins. |

### UI keymaps

| Key      | Action                                              |
|----------|-----------------------------------------------------|
| `q`      | close                                               |
| `R`      | refresh                                             |
| `<CR>`   | toggle plugin detail (src / rev / version / triggers / build) |
| `U`      | update plugin under cursor                          |
| `V`      | review (audit) plugin under cursor                  |
| `X`      | clean plugin under cursor (confirm prompt)          |
| `H` / `L`| previous / next tab (Home / Update / Clean / Log)   |
| `?`      | help                                                |

The Update / Clean / Log tabs are placeholders in v1 — use the corresponding
`:Pakku <cmd>` invocations from the command line.

`:checkhealth pakku` reports environment.

## Pre-flight update audit

`:Pakku review` fetches each plugin's remote without applying, then inspects
the incoming range for tamper signals:

- **Force-push** — current HEAD is not an ancestor of the fetch target.
  Indicates the upstream rewrote history; verify before accepting.
- **Tag drift** — when a spec pins `version = "v1.0"` but the fetched
  commit for that tag has changed. Catches the "maintainer moved the
  v1.0 tag to a new commit" attack.

The floating buffer lists every plugin's current → target SHA, all findings
prefixed with `!`, and the commit log between the two revs. Run before
`:Pakku update` to gate the actual apply.

New-contributor detection (warn when a commit in the range is authored by an
email never seen for this plugin before) is queued for v0.3 — requires a
persisted author state file.

## Security model

pakku enforces three policies *before* `vim.pack.add()` ever runs:

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

When `scanner.enabled = true`, pakku invokes up to three aegis-cli
subcommands per install/update event (each toggleable):

1. **`aegis analyze --ecosystem neovim <path> --json`** — Lua AST capability
   scan via tree-sitter. Flags `shell-spawn` (`os.execute`, `vim.fn.system`,
   `vim.fn.jobstart`), `dynamic-eval` (`loadstring`, `vim.api.nvim_exec`),
   `net-egress` (`vim.uv.new_tcp`, `socket.http`), `env-read`, `fs-write`,
   `install-hook-exec` (`ffi.load`), `raw-ip-literal`, `binary-dropper`.
   Emits per-plugin `verdict` (`safe`/`review`/`prompt`/`block`),
   `risk_score`, and `capabilities`. Requires aegis ≥ v0.27 (Lua scanner
   shipped in `feat(neovim)`).
2. **`aegis actions scan <path> --json`** — flags malicious GitHub Actions
   workflows shipped inside the plugin repo.
3. **`aegis sbom --local <path>`** — opt-in CycloneDX inventory. Only useful
   for plugins bundling manifest-bearing deps (`go.nvim` has `go.mod`,
   `blink.cmp` has Cargo workspaces). Off by default.

Reports written to `stdpath('state')/pakku/scans/<name>.{analyze,actions}.json`.

### Severity → log level

| aegis verdict | `vim.notify` level |
|---------------|--------------------|
| `safe`        | INFO               |
| `review`      | INFO               |
| `prompt`      | WARN               |
| `block`       | ERROR              |

### Setup config

```lua
scanner = {
  enabled  = true,
  bin      = "aegis",
  on       = { "install", "update" },  -- when to auto-scan
  analyze  = true,                     -- Lua AST capability scan
  actions  = true,                     -- GH Actions workflow scan
  sbom     = false,                    -- CycloneDX (opt-in)
  evidence = false,                    -- include --evidence (file:line snippets)
  fail_on  = nil,                      -- aegis --fail-on for actions
}
```

### Manual

`:Pakku scan` runs the configured scanners over every installed plugin.
`:Pakku scan <name>` targets one.

### Pre-activation gate

`scanner.gate` controls whether plugins that fail the synchronous capability
scan are blocked from `:packadd` (§2.1 of the safety spec).

| Mode      | Behavior                                                            |
|-----------|---------------------------------------------------------------------|
| `"off"`   | No gate. Plugins load regardless of verdict.                        |
| `"block"` (default) | Refuse load when verdict is `block`. Allow `prompt`/`review`/`safe` (`prompt` emits WARN). |
| `"prompt"`| Refuse load when verdict is `block` OR `prompt`. Stricter.          |

The gate scan is cached by `(plugin_name, commit_sha)` at
`stdpath('state')/pakku/scans/<name>-<rev>.cache.json`. Subsequent nvim
launches reuse the cached verdict — the synchronous aegis call only runs
when a plugin's pinned SHA changes.

When aegis is missing, the gate **fails open** (notifies WARN, plugins load).
Set `scanner.bin = "/required/path/to/aegis"` to harden if you'd rather fail
closed.

## Lockfile

pakku does not write a lockfile. `vim.pack` writes
`$XDG_CONFIG_HOME/nvim/nvim-pack-lock.json`. Commit it to your dotfiles.

## License

MIT.

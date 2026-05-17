-- luacheck config for pakku.nvim
std = "lua51+luajit"

-- Neovim globals
globals = {
  "vim",
}

-- _G is intentionally used in tests
read_globals = {
  "_G",
}

-- Tone down noise on intentional patterns.
ignore = {
  "212",  -- unused argument
  "631",  -- line too long (stylua governs line width)
  "542",  -- empty if branch (intentional in policy short-circuits)
}

files["tests/"] = {
  ignore = { "111", "112", "113", "121", "122", "131", "143" },  -- global access in fixtures
}

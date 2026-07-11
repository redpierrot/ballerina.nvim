std = "luajit"
-- A full global (not read_globals): assigning to vim fields
-- (vim.opt_local.*, vim.b.*, vim.env.*) is normal in a Neovim plugin.
globals = { "vim" }
max_line_length = 120

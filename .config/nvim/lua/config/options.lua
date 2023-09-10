-- line numbers
vim.opt.relativenumber = true
vim.opt.number = true

-- tabs & indentation
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.expandtab = true
vim.opt.smartindent = true
vim.opt.wrap = false

-- search
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- cursor
vim.opt.scrolloff = 10

-- appearance
vim.opt.termguicolors = true
vim.opt.background = "dark"
vim.opt.signcolumn = "yes"
vim.opt.colorcolumn = "100"
vim.opt.fillchars:append("eob: ") -- gets rid of ~ at end of file
vim.opt.cursorline = true
vim.opt.cursorlineopt = "number"

-- system
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.undofile = true

-- editing
vim.opt.clipboard:append("unnamedplus") -- use system clipboard
vim.opt.iskeyword:append("-") -- treats "-" as part of a word

-- window management
vim.opt.splitright = true
vim.opt.splitbelow = true

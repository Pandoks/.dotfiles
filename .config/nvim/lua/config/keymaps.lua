vim.g.mapleader = " "

vim.keymap.set("n", "<leader>nh", ":nohl<CR>", {desc = "Clear highlights"})

vim.keymap.set("n", "<leader>|", "<C-w>v", {desc = "Split window vertically"})
vim.keymap.set("n", "<leader>-", "<C-w>s", {desc = "Split window horizontally"})

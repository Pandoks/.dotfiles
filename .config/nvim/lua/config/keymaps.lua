vim.g.mapleader = " "

vim.keymap.set("n", "<leader>nh", ":nohl<CR>", { desc = "Clear highlights" })

vim.keymap.set("n", "<leader>|", "<C-w>v", { desc = "Split window vertically" })
vim.keymap.set("n", "<leader>-", "<C-w>s", { desc = "Split window horizontally" })

vim.keymap.set("n", "U", "<C-r>", { noremap = true, silent = true, desc = "Redo" })

vim.keymap.set("n", "H", "^", { noremap = true, desc = "Jump to beginning of line" })
vim.keymap.set("n", "L", "$", { noremap = true, desc = "Jump to end of line" })

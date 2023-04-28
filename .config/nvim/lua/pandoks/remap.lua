vim.g.mapleader = " "
vim.keymap.set("n", "<leader>v", vim.cmd.Ex)
vim.keymap.set("n", "<leader>nh", ":nohl<CR>")

vim.keymap.set("n", "<leader>+", "<C-a>")
vim.keymap.set("n", "<leader>-", "<C-x>")

vim.keymap.set("n", "<leader>sv", "<C-w>v") -- split window vertically
vim.keymap.set("n", "<leader>sh", "<C-w>s") -- split window horizontally
vim.keymap.set("n", "<leader>se", "<C-w>=") -- make split windows equal width
vim.keymap.set("n", "<leader>sw", ":close<CR>") -- close current split window

vim.keymap.set("n", "<leader>tt", ":tabnew<CR>") -- open new tab
vim.keymap.set("n", "<leader>tw", ":tabclose<CR>") -- close current tab
vim.keymap.set("n", "<leader>t]", ":tabn<CR>") -- go to next tab
vim.keymap.set("n", "<leader>t[", ":tabp<CR>") -- go to previous tab

vim.keymap.set("n", "<leader>sm", ":MaximizerToggle<CR>") -- maximizes current split window

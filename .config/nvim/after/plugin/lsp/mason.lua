local mason = require("mason")
local masonlspconfig = require("mason-lspconfig")
local mason_null_ls = require("mason-null-ls")

mason.setup()
masonlspconfig.setup()

mason_null_ls.setup({
	automatic_setup = true,
	automatic_installation = true,
})

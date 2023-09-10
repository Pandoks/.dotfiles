return {
	{
		"williamboman/mason-lspconfig.nvim",
		dependencies = {
			{ "williamboman/mason.nvim", config = true },
		},
		opts = {
			ensure_installed = {
				"clangd",
				"lua_ls",
				"pyright",
				"ltex",
				"tsserver",
				"svelte",
				"tailwindcss",
				"html",
				"cssls",
			},
			automatic_installation = true,
		},
	},
	{
		"jay-babu/mason-nvim-dap.nvim",
		dependencies = {
			{ "williamboman/mason.nvim", config = true },
		},
		{ handlers = nil },
	},
}

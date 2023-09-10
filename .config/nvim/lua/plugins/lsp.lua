return {
	"neovim/nvim-lspconfig",
	event = "InsertEnter",
	dependencies = {
		"williamboman/mason-lspconfig.nvim",
		"hrsh7th/cmp-nvim-lsp",
		{ "antosha417/nvim-lsp-file-operations", config = true },
	},
	config = function()
		local lspconfig = require("lspconfig")

		local signs = { Error = " ", Warn = " ", Hint = "", Info = " " }
		for type, icon in pairs(signs) do
			local hl = "DiagnosticSign" .. type
			vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = "" })
		end

		vim.lsp.handlers["textDocument/hover"] = vim.lsp.with(vim.lsp.handlers.hover, { border = "rounded" })
		vim.lsp.handlers["textDocument/signatureHelp"] =
			vim.lsp.with(vim.lsp.handlers.signature_help, { border = "rounded" })
		vim.diagnostic.config({
			float = {
				border = "rounded",
			},
		})

		local on_attach = function(_, bufnr)
			local opts = { noremap = true, silent = true, buffer = bufnr }

			opts.desc = "Show LSP references"
			vim.keymap.set("n", "<leader>fr", "<cmd>Telescope lsp_references<cr>", opts)
			opts.desc = "Show code actions"
			vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
			opts.desc = "Show documentation under cursor"
			vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
			opts.desc = "Rename"
			vim.keymap.set("n", "<leader>r", vim.lsp.buf.rename, opts)

			-- diagnostics
			opts.desc = "Show line diagnostics"
			vim.keymap.set("n", "<leader>df", vim.diagnostic.open_float, opts)
			opts.desc = "Go to previous diagnostic"
			vim.keymap.set("n", "<leader>h", vim.diagnostic.goto_prev, opts)
			opts.desc = "Go to next diagnostic"
			vim.keymap.set("n", "<leader>l", vim.diagnostic.goto_next, opts)
			opts.desc = "List of diagnostics"
			vim.keymap.set("n", "<leader>dd", "<cmd>Telescope diagnostic bufnr=0<cr>", opts)

			-- go tos
			opts.desc = "Go to declaration"
			vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)
			opts.desc = "Show definitions"
			vim.keymap.set("n", "gd", "<cmd>Telescope lsp_definitions<cr>", opts)
			opts.desc = "Show implementations"
			vim.keymap.set("n", "gi", "<cmd>Telescope lsp_implementations<cr>", opts)
			opts.desc = "Show type definitions"
			vim.keymap.set("n", "gt", "<cmd>Telescope lsp_type_definitions<cr>", opts)
		end
		local capabilities = require("cmp_nvim_lsp").default_capabilities()

		lspconfig["lua_ls"].setup({
			capabilities = capabilities,
			on_attach = on_attach,
			settings = {
				Lua = {
					diagnostics = {
						globals = { "vim", "hs" },
					},
				},
			},
		})

		local servers = { "svelte", "tsserver" }
		for _, lsp in ipairs(servers) do
			lspconfig[lsp].setup({
				capabilities = capabilities,
				on_attach = on_attach,
			})
		end
	end,
}

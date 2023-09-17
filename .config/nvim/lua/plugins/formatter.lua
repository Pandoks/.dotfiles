return {
	"stevearc/conform.nvim",
	event = "BufWritePre",
	opts = {
		formatters_by_ft = {
			lua = { "stylua" },
			sh = { "shfmt" },
			c = { "clang_format" },
			javascript = { "prettier" },
			typescript = { "prettier" },
			svelte = { "prettier" },
			json = { "prettier" },
			yaml = { "prettier" },
			markdown = { "prettier" },
			["*"] = { "trim_whitespace" },
		},
		format_on_save = {
			timeout_ms = 1000,
			lsp_fallback = true,
		},
		notify_on_error = false,
	},
}

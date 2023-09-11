return {
	"mhartington/formatter.nvim",
	event = "BufWritePre",
	keys = {
		{ "<leader>F", "<cmd>Format<cr>", mode = "n", desc = "Format the file" },
	},
	config = function()
		local mason = vim.fn.stdpath("data") .. "/mason/bin/"
		local opts = {
			logging = false,
			filetype = {
				lua = {
					require("formatter.filetypes.lua").stylua,
					ignore_exitcode = true,
				},
				sh = {
					require("formatter.filetypes.sh").shfmt,
					ignore_exitcode = true,
				},
				["*"] = {
					require("formatter.filetypes.any").remove_trailing_whitespace,
					ignore_exitcode = true,
				},
			},
		}
		require("formatter").setup(opts)

		-- format after save
		vim.api.nvim_create_augroup("FormatAutogroup", { clear = true })
		vim.api.nvim_create_autocmd({ "BufWritePost" }, {
			group = "FormatAutogroup",
			command = "FormatWrite",
		})
	end,
}

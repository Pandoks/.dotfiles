return {
	"iamcco/markdown-preview.nvim",
	build = function()
		vim.fn["mkdp#util#install"]()
	end,
	keys = {
		{ "<leader>p", "<cmd>MarkdownPreviewToggle<cr>", mode = "n", desc = "Toggle previewer" },
	},
}

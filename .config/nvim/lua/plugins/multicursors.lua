return {
	"smoka7/multicursors.nvim",
	dependencies = {
		"nvim-treesitter/nvim-treesitter",
		"anuvyklack/hydra.nvim",
	},
	opts = {
		hint_config = false,
	},
	cmd = { "MCstart", "MCvisual", "MCclear", "MCpattern", "MCvisualPattern", "MCunderCursor" },
	keys = {
		{
			mode = { "v", "n" },
			"<leader>m",
			"<cmd>MCstart<cr>",
			desc = "Create a selection for selected text or word under the cursor",
		},
	},
}

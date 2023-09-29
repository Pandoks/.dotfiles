return {
	"lukas-reineke/indent-blankline.nvim",
	main = "ibl",
	event = { "BufReadPre", "BufNewFile" },
	opts = {
		indent = {
			char = "│",
		},
		scope = {
			show_start = false,
			include = {
				node_type = {
					["*"] = { "*" },
				},
			},
		},
	},
}

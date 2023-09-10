return {
	"nvim-lualine/lualine.nvim",
	dependencies = { "anuvyklack/hydra.nvim" },
	config = function()
		local hydra = require("hydra.statusline")

		local opts = {
			options = {
				theme = "catppuccin",
				component_separators = "",
				section_separators = "",
				disabled_filetypes = {
					statusline = { "NvimTree" },
				},
			},
			sections = {
				lualine_a = {
					{
						"mode",
						cond = function()
							return not hydra.is_active()
						end,
					},
					{ hydra.get_name, cond = hydra.is_active },
				},
				lualine_c = {
					{
						"filename",
						path = 1,
					},
				},
			},
			inactive_sections = {
				lualine_c = {
					{
						"filename",
						path = 1,
					},
				},
			},
		}

		require("lualine").setup(opts)
	end,
}

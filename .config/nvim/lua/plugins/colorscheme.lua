return {
	"catppuccin/nvim",
	priority = 69420,
	name = "catppuccin",
	opts = {
		transparent_background = true,
		highlight_overrides = {
			mocha = function(mocha)
				return {
					Folded = { bg = mocha.mantle },
					Pmenu = { bg = mocha.crust },
				}
			end,
		},
		integrations = {
			barbar = true,
			barbecue = {
				dim_dirname = true, -- directory name is dimmed by default
				bold_basename = true,
				dim_context = false,
				alt_background = false,
			},
			cmp = true,
			dap = {
				enabled = true,
				enable_ui = true, -- enable nvim-dap-ui
			},
			flash = true,
			gitsigns = true,
			indent_blankline = {
				enabled = true,
				scope_color = "blue",
				colored_indent_levels = false,
			},
			mason = true,
			markdown = true,
			mini = true,
			native_lsp = {
				enabled = true,
				virtual_text = {
					errors = { "italic" },
					hints = { "italic" },
					warnings = { "italic" },
					information = { "italic" },
				},
				underlines = {
					errors = { "underline" },
					hints = { "underline" },
					warnings = { "underline" },
					information = { "underline" },
				},
				inlay_hints = {
					background = false,
				},
			},
			nvimtree = true,
			rainbow_delimiters = true,
			telescope = { enabled = true },
			treesitter = true,
			ufo = true,
			-- For more plugins integrations please scroll down (https://github.com/catppuccin/nvim#integrations)
		},
	},
	config = function(_, opts)
		require("catppuccin").setup(opts)
		vim.cmd("colorscheme catppuccin")
	end,
}

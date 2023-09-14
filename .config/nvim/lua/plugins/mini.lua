return {
	{
		"echasnovski/mini.move",
		version = "*",
		opts = {
			mappings = {
				-- Move visual selection in Visual mode. Defaults are Alt (Meta) + hjkl. left = '<C-S-M-h>',
				left = "<C-S-M-h>",
				down = "<C-S-M-j>",
				up = "<C-S-M-k>",
				right = "<C-S-M-l>",

				-- Move current line in Normal mode line_left = '<C-S-M-h>',
				line_left = "<C-S-M-h>",
				line_down = "<C-S-M-j>",
				line_up = "<C-S-M-k>",
				line_right = "<C-S-M-l>",
			},
		},
		keys = {
			"<C-S-M-h>",
			"<C-S-M-j>",
			"<C-S-M-k>",
			"<C-S-M-l>",
		},
	},
	{
		"echasnovski/mini.surround",
		version = "*",
    event = "ModeChanged",
		opts = {
			mappings = {
				add = "sa", -- Add surrounding in Normal and Visual modes
				delete = "sd", -- Delete surrounding
				find = "sf", -- Find surrounding (to the right)
				find_left = "sF", -- Find surrounding (to the left)
				highlight = "sh", -- Highlight surrounding
				replace = "sr", -- Replace surrounding
			},
		},
		keys = {
			"s",
		},
	},
}

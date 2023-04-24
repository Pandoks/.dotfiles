local lspsaga = require("lspsaga")

lspsaga.setup({
	-- keybinds for navigation in lspsaga window
	scroll_preview = { scroll_down = "<C-f>", scroll_up = "<C-b>" },
	preview = {
		lines_above = 0,
		lines_below = 10,
	},
	finder = {
		--percentage
		max_height = 0.5,
		force_max_height = false,
		keys = {
			jump_to = "p",
			edit = { "o", "<CR>" },
			vsplit = "s",
			split = "i",
			tabe = "t",
			tabnew = "r",
			quit = { "q", "<ESC>" },
			close_in_preview = "<ESC>",
		},
	},
	definition = {
		edit = "<C-c>o",
		vsplit = "<C-c>v",
		split = "<C-c>i",
		tabe = "<C-c>t",
		quit = "<ESC>",
	},
	code_action = {
		num_shortcut = true,
		show_server_name = false,
		extend_gitsigns = true,
		keys = {
			-- string | table type
			quit = "<ESC>",
			exec = "<CR>",
		},
	},
	lightbulb = {
		enable = false,
		enable_in_insert = true,
		sign = false,
		sign_priority = 40,
		virtual_text = true,
	},
	diagnostic = {
		on_insert = false,
		on_insert_follow = false,
		insert_winblend = 0,
		show_virt_line = false,
		show_code_action = true,
		show_source = true,
		jump_num_shortcut = true,
		--1 is max
		max_width = 0.7,
		custom_fix = nil,
		custom_msg = nil,
		text_hl_follow = false,
		border_follow = true,
		keys = {
			exec_action = "o",
			quit = "<ESC>",
			go_action = "g",
		},
	},
	rename = {
		quit = "<ESC>",
		exec = "<CR>",
		mark = "x",
		confirm = "<CR>",
		in_select = true,
	},
})

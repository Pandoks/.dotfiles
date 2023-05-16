local builtin = require("telescope.builtin")
local actions = require("telescope.actions")
local config = require("telescope.config")

-- clone default telscope configs
local vimgrep_arg = { unpack(config.values.vimgrep_arguments) }
-- seach in hidden files
table.insert(vimgrep_arg, "--hidden")
-- don't search in .git
table.insert(vimgrep_arg, "--glob")
table.insert(vimgrep_arg, "!**/.git/**")

vim.keymap.set("n", "<leader>f", builtin.find_files, {})
vim.keymap.set("n", "<leader>g", builtin.git_files, {})
vim.keymap.set("n", "<leader>s", builtin.live_grep, {})

require("telescope").setup({
	defaults = {
		-- Default configuration for telescope goes here:
		-- config_key = value,
		vimgrep_arguments = vimgrep_arg,
		mappings = {
			i = {
				-- map actions.which_key to <C-h> (default: <C-/>)
				-- actions.which_key shows the mappings for your picker,
				-- e.g. git_{create, delete, ...}_branch for the git_branches picker
				-- ["<C-h>"] = "which_key",
				["<esc>"] = actions.close,
			},
		},
	},
	pickers = {
		-- Default configuration for builtin pickers goes here:
		-- picker_name = {
		--   picker_config_key = value,
		--   ...
		-- }
		-- Now the picker_config_key will be applied every time you call this
		-- builtin picker
		find_files = {
			find_command = { "rg", "--files", "--hidden", "--glob", "!**/.git/**" },
		},
	},
	extsions = {
		-- Your extension configuration goes here:
		-- extension_name = {
		--   extension_config_key = value,
		-- }
		-- please take a look at the readme of the extension you want to configure
	},
})

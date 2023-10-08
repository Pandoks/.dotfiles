return {
	"Pandoks/sg.nvim",
	branch = "master",
	event = { "InsertEnter" },
	dependencies = { "nvim-lua/plenary.nvim" },
	opts = {
		enable_cody = true,
	},
	keys = {
		{ "<leader>u", "<cmd>CodyToggle<cr>", mode = "n", desc = "Toggle Cody AI chat" },
	},
}

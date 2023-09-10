return {
	{
		"rcarriga/nvim-dap-ui",
		dependencies = {
			"mfussenegger/nvim-dap",
		},
		opts = {},
		keys = {
			{ "<leader>db", "<cmd>lua require('dapui').toggle()<cr>", mode = "n", desc = "Toggle debugger mode" },
		},
	},
	{
		"mfussenegger/nvim-dap",
		config = function()
			require("dap")

			vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DapBreakpoint", linehl = "", numhl = "" })
			vim.fn.sign_define("DapBreakpointCondition", { text = "●", texthl = "DapBreakpointCondition", linehl = "", numhl = "" })
			vim.fn.sign_define("DapLogPoint", { text = "◆", texthl = "DapLogPoint", linehl = "", numhl = "" })
		end,
	},
}

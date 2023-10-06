return {
	{
		"rcarriga/nvim-dap-ui",
		dependencies = {
			"mfussenegger/nvim-dap",
			"theHamsta/nvim-dap-virtual-text",
		},
		keys = {
			{
				"<leader>du",
				function()
					require("dapui").toggle()
				end,
				mode = "n",
				desc = "Toggle debugger mode",
			},
		},
		config = function()
			local dap = require("dap")
			local dapui = require("dapui")
			dapui.setup()
			dap.listeners.after.event_initialized["dapui_config"] = function()
				dapui.open()
			end
			dap.listeners.before.event_terminated["dapui_config"] = function()
				dapui.close()
			end
			dap.listeners.before.event_exited["dapui_config"] = function()
				dapui.close()
			end
		end,
	},
	{
		"mfussenegger/nvim-dap",
		dependencies = {
			"mfussenegger/nvim-dap-python",
		},
		keys = {
			{
				"dt",
				function()
					require("dap").toggle_breakpoint()
				end,
				mode = "n",
				desc = "Toggle a debugging breakpoint",
			},
			{
				"<leader>dd",
				function()
					require("dap").terminate()
				end,
				mode = "n",
				desc = "Stop debugging",
			},
			{
				"<leader>db",
				function()
					require("dap").continue()
				end,
				mode = "n",
				desc = "Start debugging",
			},
			{
				"<leader>dr",
				function()
					require("dap").restart()
				end,
				mode = "n",
				desc = "Restart debugging",
			},
			{
				"<leader>dn",
				function()
					require("dap").step_over()
				end,
				mode = "n",
				desc = "Step over",
			},
			{
				"<leader>dp",
				function()
					require("dap").step_back()
				end,
				mode = "n",
				desc = "Step back",
			},
			{
				"<leader>di",
				function()
					require("dap").step_into()
				end,
				mode = "n",
				desc = "Step into",
			},
			{
				"<leader>do",
				function()
					require("dap").step_out()
				end,
				mode = "n",
				desc = "Step out",
			},
		},
		config = function()
			vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DapBreakpoint", linehl = "", numhl = "" })
			vim.fn.sign_define(
				"DapBreakpointCondition",
				{ text = "●", texthl = "DapBreakpointCondition", linehl = "", numhl = "" }
			)
			vim.fn.sign_define("DapLogPoint", { text = "◆", texthl = "DapLogPoint", linehl = "", numhl = "" })
		end,
	},
	{
		"theHamsta/nvim-dap-virtual-text",
		lazy = true,
		opts = {
			enabled = true,
		},
	},
	{
		"mfussenegger/nvim-dap-python",
		ft = "python",
		config = function()
			require("dap-python").setup("~/.local/share/nvim/mason/packages/debugpy/venv/bin/python")
		end,
	},
}

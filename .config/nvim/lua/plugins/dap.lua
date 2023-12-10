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
      {
        "<leader>db", -- make sure dap-ui is loaded when starting debugger
        function()
          require("dap").continue()
        end,
        mode = "n",
        desc = "Start debugging",
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
      "williamboman/mason.nvim",
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
        "<leader>dT",
        function()
          require("dap").terminate()
        end,
        mode = "n",
        desc = "Stop debugging",
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
      local dap = require("dap")
      vim.fn.sign_define(
        "DapBreakpoint",
        { text = "●", texthl = "DapBreakpoint", linehl = "", numhl = "" }
      )
      vim.fn.sign_define(
        "DapBreakpointCondition",
        { text = "", texthl = "DapBreakpointCondition", linehl = "", numhl = "" }
      )
      vim.fn.sign_define(
        "DapLogPoint",
        { text = "󰸥", texthl = "DapLogPoint", linehl = "", numhl = "" }
      )
      vim.fn.sign_define(
        "DapBreakpointRejected",
        { text = "", texthl = "DapLogPoint", linehl = "", numhl = "" }
      )

      -- js debugger
      dap.adapters["pwa-node"] = {
        type = "server",
        host = "localhost",
        port = "${port}",
        executable = {
          command = "node",
          args = {
            require("mason-registry").get_package("js-debug-adapter"):get_install_path()
              .. "/js-debug/src/dapDebugServer.js",
            "${port}",
          },
        },
      }
      for _, language in ipairs({ "javascript", "typescript", "javascriptreact", "typescriptreact" }) do
        dap.configurations[language] = {
          {
            type = "pwa-node",
            request = "launch",
            name = "Launch File",
            program = "${file}",
            cwd = "${workspaceFolder}",
            sourceMaps = true,
          },
          {
            type = "pwa-node",
            request = "attach",
            name = "Attach Runtime (Remember --inspect)",
            processId = require("dap.utils").pick_process,
            cwd = "${workspaceFolder}",
            sourceMaps = true,
          },
        }
      end
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
      require("dap-python").setup("~/.pyenv/versions/3.9.18/bin/python3.9")
    end,
  },
}

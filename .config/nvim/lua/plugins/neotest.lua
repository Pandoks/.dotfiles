return {
  "nvim-neotest/neotest",
  lazy = true,
  dependencies = {
    "nvim-neotest/nvim-nio",
    "nvim-lua/plenary.nvim",
    "antoinemadec/FixCursorHold.nvim",
    "nvim-treesitter/nvim-treesitter",
    "marilari88/neotest-vitest",
    "thenbe/neotest-playwright",
    "nvim-neotest/neotest-python",
  },
  config = function()
    require("neotest").setup({
      adapters = {
        require("neotest-playwright").adapter({
          options = {
            persist_project_selection = true,
            enable_dynamic_test_discovery = true,
          },
        }),
        require("neotest-vitest")({
          filter_dir = function(name, rel_path, root)
            return name ~= "node_modules"
          end,
        }),
        require("neotest-python"),
      },
    })
  end,
  keys = {
    {
      "<leader>t",
      function()
        require("neotest").summary.toggle()
      end,
      mode = "n",
      desc = "Toggle test panel",
    },
  },
}

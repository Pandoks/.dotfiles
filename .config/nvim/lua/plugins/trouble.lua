return {
  "folke/trouble.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  cmd = "Trouble",
  opts = {
    focus = true,
    modes = {
      mode = "diagnostics",
      preview = {
        type = "split",
        relative = "win",
        position = "right",
        size = 0.3,
      },
    },
  },
  keys = {
    {
      "<leader>T",
      "<cmd>Trouble diagnostics toggle<cr>",
      mode = { "n" },
      desc = "Toggle trouble",
    },
  },
}

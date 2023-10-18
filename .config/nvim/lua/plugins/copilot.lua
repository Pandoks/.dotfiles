return {
  {
    "zbirenbaum/copilot.lua",
    event = { "BufReadPre", "BufNewFile" },
    opts = {
      panel = {
        enabled = true,
        layout = {
          position = "right",
          ratio = 0.3,
        },
      },
    },
    suggestion = {
      enabled = false,
    },
    filetypes = {
      yaml = false,
      markdown = false,
      help = false,
      gitcommit = false,
      gitrebase = false,
      hgcommit = false,
      svn = false,
      cvs = false,
      ["."] = false,
    },
  },
  {
    "zbirenbaum/copilot-cmp",
    event = { "InsertEnter" },
    dependencies = {
      "hrsh7th/nvim-cmp",
      "zbirenbaum/copilot.lua",
    },
    config = function()
      require("copilot_cmp").setup()
    end,
  },
}

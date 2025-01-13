return {
  "folke/flash.nvim",
  opts = {
    modes = {
      char = {
        enabled = false,
      },
      search = {
        enabled = false,
      },
    },
  },
  keys = {
    {
      "se",
      function()
        require("flash").jump({
          search = {
            mode = function(str)
              return "\\<" .. str
            end,
          },
        })
      end,
      mode = { "n", "x", "o" },
      desc = "Flash to location",
    },
    {
      "<leader>st",
      function()
        require("flash").treesitter()
      end,
      mode = { "n", "x", "o" },
      desc = "Flash select a treesitter section",
    },
  },
}

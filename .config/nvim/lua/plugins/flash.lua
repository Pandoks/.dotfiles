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
      "<leader>t",
      function()
        require("flash").treesitter()
      end,
      mode = { "n", "x", "o" },
      desc = "Flash select a treesitter section",
    },
    {
      "<leader>T",
      function()
        require("flash").treesitter_search()
      end,
      mode = { "n", "x", "o" },
      desc = "Flash search and select a treesitter section or word",
    },
  },
}

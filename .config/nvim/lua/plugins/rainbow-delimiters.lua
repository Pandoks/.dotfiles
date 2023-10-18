return {
  "HiPhish/rainbow-delimiters.nvim",
  opts = {
    query = {
      -- for language support check out https://github.com/HiPhish/rainbow-delimiters.nvim/tree/master/queries
      latex = "rainbow-blocks",
      lua = "rainbow-blocks",
    },
  },
  config = function(_, opts)
    vim.g.rainbow_delimiters = opts
  end,
}

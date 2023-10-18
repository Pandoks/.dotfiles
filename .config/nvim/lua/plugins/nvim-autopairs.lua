return {
  "windwp/nvim-autopairs",
  dependencies = {
    "hrsh7th/nvim-cmp",
    "windwp/nvim-ts-autotag",
  },
  event = "InsertEnter",
  opts = {
    check_ts = true,
  },
  config = function(_, opts)
    require("nvim-autopairs").setup(opts)
    require("nvim-ts-autotag").setup()
    require("cmp").event:on(
      "confirm_done",
      require("nvim-autopairs.completion.cmp").on_confirm_done()
    )
  end,
}

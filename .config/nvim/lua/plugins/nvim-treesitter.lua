return {
  "nvim-treesitter/nvim-treesitter",
  dependencies = {
    "windwp/nvim-ts-autotag",
  },
  build = ":TSUpdate",
  opts = {
    ensure_installed = {
      "c",
      "lua",
      "python",
      "markdown",
      "markdown_inline",
      "javascript",
      "typescript",
      "svelte",
      "comment",
    },
    auto_install = true,
    auto_tag = {
      enable = true,
    },
    highlight = {
      enable = true,
    },
    indent = {
      enable = true,
    },
  },
  config = function(_, opts)
    require("nvim-treesitter.configs").setup(opts)
  end,
}

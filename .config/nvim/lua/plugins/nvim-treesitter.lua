return {
  "nvim-treesitter/nvim-treesitter",
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
      "html",
      "css",
      "svelte",
      "comment",
      "yaml",
      "helm",
    },
    auto_install = true,
    highlight = { enable = true },
    indent = { enable = true, disable = { "yaml", "helm" } },
  },
  config = function(_, opts)
    require("nvim-treesitter.configs").setup(opts)

    vim.filetype.add({
      pattern = { [".*/charts/.*/templates/.*%.ya?ml"] = "helm" },
      extension = { tpl = "helm" },
    })
  end,
}

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
      "gotmpl",
    },
    auto_install = true,
    highlight = {
      enable = true,
    },
    indent = {
      enable = true,
      disable = { "yaml", "gotmpl" },
    },
  },
  config = function(_, opts)
    require("nvim-treesitter.configs").setup(opts)

    if vim.treesitter.language and vim.treesitter.language.register then
      vim.treesitter.language.register("gotmpl", "helm")
    else
      local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
      parser_config.gotmpl = parser_config.gotmpl or {}
      parser_config.gotmpl.filetype_to_parsername = { "helm", "gotmpl" }
    end

    vim.filetype.add({
      pattern = { [".*/charts/.*/templates/.*%.ya?ml"] = "helm" },
      extension = { tpl = "helm" },
    })
  end,
}

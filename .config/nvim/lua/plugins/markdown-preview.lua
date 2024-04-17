return {
  "iamcco/markdown-preview.nvim",
  ft = { "markdown" },
  build = function()
    vim.fn["mkdp#util#install"]()
  end,
  keys = {
    { "<leader>p", "<cmd>MarkdownPreviewToggle<cr>", mode = "n", desc = "Toggle previewer" },
  },
}

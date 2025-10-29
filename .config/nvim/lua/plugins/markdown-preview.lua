return {
  "iamcco/markdown-preview.nvim",
  ft = { "markdown" },
  build = "cd app && npm install && git restore .",
  init = function()
    vim.g.mkdp_filetypes = { "markdown" }
  end,
  keys = {
    { "<leader>p", "<cmd>MarkdownPreviewToggle<cr>", mode = "n", desc = "Toggle previewer" },
  },
}

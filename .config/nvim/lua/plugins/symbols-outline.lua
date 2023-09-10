return {
  "simrat39/symbols-outline.nvim",
  lazy = false,
  opts = {
    keymaps = {
      focus_location = "<S-cr>",
      fold_all = "H",
      unfold_all = "L",
      toggle_preview = "<C-space>",
      hover_symbol = "K",
    },
  },
  keys = {
    {"<leader>s", "<cmd>SymbolsOutline<cr>", mode = "n", desc = "Open up symbols view"},
  },
}

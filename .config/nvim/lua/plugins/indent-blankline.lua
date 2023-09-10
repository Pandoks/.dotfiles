return {
  "lukas-reineke/indent-blankline.nvim",
  opts = {
    show_current_context = true,
    space_char_blankline = " ",
  },
  config = function(_, opts)
    vim.opt.list = true
    vim.g.indent_blankline_filetype_exclude = {'dashboard'}
    require("indent_blankline").setup(opts)
  end,
}

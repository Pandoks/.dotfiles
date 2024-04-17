return {
  "nvim-lualine/lualine.nvim",
  opts = {
    options = {
      theme = "catppuccin",
      component_separators = "",
      section_separators = "",
      disabled_filetypes = {
        statusline = { "NvimTree" },
      },
    },
    sections = {
      lualine_a = {
        {
          "mode",
        },
      },
      lualine_c = {
        {
          "filename",
          path = 1,
        },
      },
    },
    inactive_sections = {
      lualine_c = {
        {
          "filename",
          path = 1,
        },
      },
    },
  },
}

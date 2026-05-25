return {
  "nvim-tree/nvim-tree.lua",
  version = "*",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  opts = {
    view = {
      number = true,
      relativenumber = true,
      width = 40,
    },
    renderer = {
      indent_markers = {
        enable = false,
      },
      icons = {
        glyphs = {
          folder = {
            arrow_closed = "",
            arrow_open = "",
          },
        },
      },
    },
    filters = {
      git_ignored = false,
    },
    filesystem_watchers = {
      enable = true,
      debounce_delay = 50,
      ignore_dirs = { "node_modules", ".git" },
    },
    update_focused_file = {
      enable = true,
      update_root = { enable = true },
    },
  },
  keys = {
    { "<leader>e", "<cmd>NvimTreeToggle<cr>", mode = "n", desc = "Toggle file explorer" },
  },
  config = function(_, opts)
    -- disable netrw at the start
    vim.g.loaded_netrw = 1
    vim.g.loaded_netrwPlugin = 1
    require("nvim-tree").setup(opts)
  end,
}

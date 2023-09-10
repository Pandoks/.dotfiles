return {
  'nvim-telescope/telescope.nvim',
  branch = '0.1.x',
  dependencies = {
    'nvim-lua/plenary.nvim',
    "debugloop/telescope-undo.nvim",
    "nvim-tree/nvim-web-devicons",
    { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' },
  },
  keys = {
    {"<leader>ff", "<cmd>Telescope find_files<cr>", mode = "n", desc = "Find files"},
    {"<leader>fg", "<cmd>Telescope live_grep<cr>", mode = "n", desc = "Grep through files"},
    {"<leader>fu", "<cmd>Telescope undo<cr>", mode = "n", desc = "test2"},

  },
  config = function()
    local telescope = require("telescope")
    local actions = require("telescope.actions")
    local undo = require("telescope-undo.actions")

    local opts = {
      defaults = {
        mappings = {
          i = {
            ["<esc>"] = actions.close,
            ["<C-j>"] = actions.move_selection_next,
            ["<C-k>"] = actions.move_selection_previous,
          },
        },
        file_ignore_patterns = {"%.git/"},
      },
      pickers = {
        find_files = {
          find_command = {
            "rg", "--files", "--hidden",
          },
        },
        live_grep = {
          additional_args = {
            "--hidden",
          },
        },
        lsp_references = { fname_width = 50, },
      },
      extensions = {
        undo = {
          mappings = {
            i = {
              ["<cr>"] = undo.restore,
            },
          },
        },
      },
    }

    telescope.setup(opts)
    telescope.load_extension("fzf")
    telescope.load_extension("undo")
  end,
}

return {
  "nvim-telescope/telescope.nvim",
  branch = "0.1.x",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-tree/nvim-web-devicons",
    "debugloop/telescope-undo.nvim",
    "jmacadie/telescope-hierarchy.nvim",
    { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
  },
  keys = {
    { "<leader>ff", "<cmd>Telescope find_files<cr>", mode = "n", desc = "Find files" },
    { "<leader>fg", "<cmd>Telescope live_grep<cr>", mode = "n", desc = "Grep through files" },
    { "<leader>fu", "<cmd>Telescope undo<cr>", mode = "n", desc = "History of edits" },
    { "<leader>fm", "<cmd>Telescope marks<cr>", mode = "n", desc = "Find marks" },
    {
      "<leader>fs",
      function()
        require("telescope.builtin").lsp_workspace_symbols({
          ignore_symbols = {
            "variable",
            "property",
          },
        })
      end,
      mode = "n",
      desc = "Find all symbols in workspace",
    },
    {
      "<leader>fo",
      "<cmd>Telescope hierarchy outgoing_calls<cr>",
      mode = "n",
      desc = "Find outgoing calls",
    },
  },
  config = function()
    local telescope = require("telescope")
    local actions = require("telescope.actions")
    local undo = require("telescope-undo.actions")

    local opts = {
      defaults = {
        layout_strategy = "flex",
        layout_config = {
          flex = {
            flip_columns = 106,
            flip_lines = 40,
          },
          vertical = {
            prompt_position = "top",
            preview_cutoff = 0,
          },
          horizontal = {
            preview_cutoff = 0,
          },
        },
        mappings = {
          i = {
            ["<esc>"] = actions.close,
            ["<C-j>"] = actions.move_selection_next,
            ["<C-k>"] = actions.move_selection_previous,
          },
        },
        file_ignore_patterns = { "%.git/" },
      },
      pickers = {
        find_files = {
          find_command = {
            "rg",
            "--files",
            "--hidden",
          },
        },
        live_grep = {
          additional_args = {
            "--hidden",
          },
        },
        lsp_references = { fname_width = 50 },
      },
      extensions = {
        hierarchy = {
          initial_multi_expand = true,
          multi_depth = 5,
          layout_strategy = "flex",
          layout_config = {
            flex = {
              flip_columns = 120,
              flip_lines = 40,
            },
            vertical = {
              prompt_position = "top",
              preview_cutoff = 0,
            },
            horizontal = {
              preview_cutoff = 0,
              preview_width = 0.62,
            },
          },
        },
        undo = {
          use_delta = true,
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
    telescope.load_extension("hierarchy")
  end,
}

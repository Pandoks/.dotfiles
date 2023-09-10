return
  {'romgrk/barbar.nvim',
    dependencies = {
      'lewis6991/gitsigns.nvim', -- OPTIONAL: for git status
      'nvim-tree/nvim-web-devicons', -- OPTIONAL: for file icons
    },
    init = function() vim.g.barbar_auto_setup = false end,
    lazy = false,
    opts =
      {
        animation = false,
        auto_hide = true,

        -- Hide inactive buffers and file extensions. Other options are `alternate`, `current`, and `visible`.
        hide = {
          current = true,       -- Hide the current buffer
          visible = true,       -- Hide visible (active) buffers
          inactive = true,      -- Hide inactive (hidden) buffers
          alternate = true,     -- Hide alternate buffers
        },

        -- Disable highlighting file icons in inactive buffers

        icons = {
          button = false,
          diagnostics = {
            [vim.diagnostic.severity.ERROR] = {enabled = true},
            [vim.diagnostic.severity.WARN] = {enabled = false},
            [vim.diagnostic.severity.INFO] = {enabled = false},
            [vim.diagnostic.severity.HINT] = {enabled = false},
          },
          separator = {left = '', right = ''},
          separator_at_end = false,

          -- Configure the icons on the bufferline based on the visibility of a buffer.
          -- Supports all the base icon options, plus `modified` and `pinned`.
          pinned = {button = '', filename = true, extension = true},
        },
        insert_at_start = true,

        sidebar_filetypes = {
          NvimTree = true,
          undotree = true,
        },
      },
    keys = {
      { "<leader>bb", "<cmd>BufferPick<cr>", mode = "n", desc = "Pick a buffer mode"},
      { "<leader>ba", "<cmd>BufferPin<cr>", mode = "n", desc = "Pin a buffer"},
    },
  }


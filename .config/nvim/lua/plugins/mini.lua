return {
  {
    "echasnovski/mini.indentscope",
    version = "*",
    event = { "BufReadPre", "BufNewFile", "ModeChanged" },
    opts = {
      draw = {
        delay = 0,
        animation = function()
          return 0
        end,
      },
      mappings = {
        object_scope = "",
        object_scope_with_border = "",
        goto_top = "",
        goto_bottom = "",
      },
      symbol = "│",
    },
  },
  {
    "echasnovski/mini.move",
    version = "*",
    opts = {
      mappings = {
        -- Move visual selection in Visual mode. Defaults are Alt (Meta) + hjkl. left = '<C-S-M-h>',
        left = "<C-M-H>",
        down = "<C-M-J>",
        up = "<C-M-K>",
        right = "<C-M-L>",

        -- Move current line in Normal mode line_left = '<C-S-M-h>',
        line_left = "<C-M-H>",
        line_down = "<C-M-J>",
        line_up = "<C-M-K>",
        line_right = "<C-M-L>",
      },
    },
  },
  {
    "echasnovski/mini.surround",
    version = "*",
    event = "ModeChanged",
    opts = {
      mappings = {
        add = "sa", -- Add surrounding in Normal and Visual modes
        delete = "sd", -- Delete surrounding
        find = "sf", -- Find surrounding (to the right)
        find_left = "sF", -- Find surrounding (to the left)
        highlight = "sh", -- Highlight surrounding
        replace = "sr", -- Replace surrounding
      },
    },
    keys = {
      "s",
    },
  },
}

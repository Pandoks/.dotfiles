return {
  {
    "echasnovski/mini.comment",
    version = "*",
    lazy = false,
    opts = {
      mappings = {
        comment = 'gc',
        comment_line = 'gcc',
      },
    },
  },
  {
    "echasnovski/mini.move",
    version = "*",
    opts = {
      mappings = {
        -- Move visual selection in Visual mode. Defaults are Alt (Meta) + hjkl. left = '<C-S-M-h>',
        right = '<C-S-M-l>',
        down = '<C-S-M-j>',
        up = '<C-S-M-k>',

        -- Move current line in Normal mode line_left = '<C-S-M-h>',
        line_right = '<C-S-M-l>',
        line_down = '<C-S-M-j>',
        line_up = '<C-S-M-k>',
      },
    },
  },
  {
    'echasnovski/mini.surround',
    lazy = false,
    version = '*',
    opts = {
      mappings = {
        add = 'sa', -- Add surrounding in Normal and Visual modes
        delete = 'sd', -- Delete surrounding
        find = 'sf', -- Find surrounding (to the right)
        find_left = 'sF', -- Find surrounding (to the left)
        highlight = 'sh', -- Highlight surrounding
        replace = 'sr', -- Replace surrounding
      },
    },
  },
}


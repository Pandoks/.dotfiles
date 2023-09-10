return {
  "aserowy/tmux.nvim",
  opts = {
    copy_sync = {
        enable = false,
    },
    navigation = {
        enable_default_keybindings = false,
        cycle_navigation = false,
    },
    resize = {
        enable_default_keybindings = false,
        resize_step_x = 5,
        resize_step_y = 5,
    }
},
keys = {
  {"<C-h>", "<cmd>lua require('tmux').move_left()<cr>", mode = "n", desc = "Move to right panel"},
  {"<C-j>", "<cmd>lua require('tmux').move_bottom()<cr>", mode = "n", desc = "Move to bottom panel"},
  {"<C-k>", "<cmd>lua require('tmux').move_top()<cr>", mode = "n", desc = "Move to top panel"},
  {"<C-l>", "<cmd>lua require('tmux').move_right()<cr>", mode = "n", desc = "Move to right panel"},
  {"<C-S-h>", "<cmd>lua require('tmux').resize_left()<cr>", mode = "n", desc = "Resize panel left"},
  {"<C-S-j>", "<cmd>lua require('tmux').resize_bottom()<cr>", mode = "n", desc = "Resize panel down"},
  {"<C-S-k>", "<cmd>lua require('tmux').resize_top()<cr>", mode = "n", desc = "Resize panel up"},
  {"<C-S-l>", "<cmd>lua require('tmux').resize_right()<cr>", mode = "n", desc = "Resize panel right"},
},
}

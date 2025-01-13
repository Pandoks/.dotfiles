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
    },
  },
  keys = {
    {
      "<C-h>",
      function()
        require("tmux").move_left()
      end,
      mode = "n",
      desc = "Move to right panel",
    },
    {
      "<C-j>",
      function()
        require("tmux").move_bottom()
      end,
      mode = "n",
      desc = "Move to bottom panel",
    },
    {
      "<C-k>",
      function()
        require("tmux").move_top()
      end,
      mode = "n",
      desc = "Move to top panel",
    },
    {
      "<C-l>",
      function()
        require("tmux").move_right()
      end,
      mode = "n",
      desc = "Move to right panel",
    },
    {
      "<C-S-H>",
      function()
        require("tmux").resize_left()
      end,
      mode = "n",
      desc = "Resize panel left",
    },
    {
      "<C-S-J>",
      function()
        require("tmux").resize_bottom()
      end,
      mode = "n",
      desc = "Resize panel down",
    },
    {
      "<C-S-K>",
      function()
        require("tmux").resize_top()
      end,
      mode = "n",
      desc = "Resize panel up",
    },
    {
      "<C-S-L>",
      function()
        require("tmux").resize_right()
      end,
      mode = "n",
      desc = "Resize panel right",
    },
  },
}

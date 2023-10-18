return {
  "laytan/cloak.nvim",
  opts = {
    patterns = {
      {
        file_pattern = ".env*",
        cloak_pattern = "=.+",
      },
      {
        file_pattern = ".Settings.zk",
        cloak_pattern = {
          ":.+",
          "?.+",
          "%s[%a%d%p]+[^%s:?]$", --[[ Codes ]]
        },
      },
      {
        file_pattern = "shortcuts.lua",
        cloak_pattern = {
          '%(".+"',
        },
      },
    },
  },
}

return {
  {
    "williamboman/mason.nvim",
    lazy = true,
    config = true,
  },
  {
    "williamboman/mason-lspconfig.nvim",
    lazy = true,
    dependencies = {
      "williamboman/mason.nvim",
    },
    opts = {
      ensure_installed = {
        "clangd",
        "bashls",
        "lua_ls",
        "pyright",
        "ltex",
        "ts_ls",
        "svelte",
        "tailwindcss",
        "html",
        "cssls",
      },
      automatic_enable = false,
    },
  },
  {
    "jay-babu/mason-nvim-dap.nvim",
    lazy = true,
    dependencies = {
      "williamboman/mason.nvim",
    },
    opts = { handlers = nil },
  },
}

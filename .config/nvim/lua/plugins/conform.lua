return {
  "stevearc/conform.nvim",
  event = "BufWritePre",
  init = function()
    vim.g.disable_autoformat = false
    vim.api.nvim_create_user_command("ConformToggle", function()
      vim.g.disable_autoformat = not vim.g.disable_autoformat
      if vim.g.disable_autoformat then
        print("Autoformatting disabled")
      else
        print("Autoformatting enabled")
      end
    end, { desc = "Toggle autoformat" })
  end,
  opts = {
    formatters_by_ft = {
      lua = { "stylua" },
      sh = { "shfmt" },
      c = { "clang_format" },
      javascript = { "prettier" },
      typescript = { "prettier" },
      svelte = { "prettier" },
      json = { "prettier" },
      yaml = { "prettier" },
      css = { "prettier" },
      markdown = { "prettier" },
      python = { "black" },
      ["_"] = { "trim_whitespace" },
    },
    formatters = {
      prettier = {
        args = { "--stdin-filepath", "$FILENAME", "--ignore-path", ".prettierignore" },
      },
      -- shfmt = {
      --   command = "~/.local/share/nvim/mason/packages/shfmt/shfmt_v3.8.0_darwin_arm64",
      -- },
    },
    format_on_save = function()
      if vim.g.disable_autoformat then
        return
      end
      return {
        timeout_ms = 1000,
        lsp_fallback = true,
      }
    end,
    notify_on_error = false,
  },
}

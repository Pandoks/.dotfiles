return {
  "mfussenegger/nvim-lint",
  event = "InsertLeave",
  config = function()
    require("lint").linters_by_ft = {}
    vim.api.nvim_create_autocmd({ "InsertLeave" }, {
      callback = function()
        require("lint").try_lint()
      end,
    })
  end,
}

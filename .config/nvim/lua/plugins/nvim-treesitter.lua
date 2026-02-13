return {
  "nvim-treesitter/nvim-treesitter",
  build = ":TSUpdate",
  lazy = false,
  config = function()
    require("nvim-treesitter").setup()

    require("nvim-treesitter").install({
      "c",
      "lua",
      "python",
      "markdown",
      "markdown_inline",
      "javascript",
      "typescript",
      "html",
      "css",
      "svelte",
      "latex",
      "typst",
      "comment",
      "yaml",
      "helm",
    })

    local disabled_indent = { yaml = true, helm = true }

    vim.api.nvim_create_autocmd("FileType", {
      callback = function(event)
        local lang = vim.treesitter.language.get_lang(event.match)
        if not pcall(vim.treesitter.language.add, lang or event.match) then
          return
        end

        pcall(vim.treesitter.start, event.buf)

        if not disabled_indent[lang or event.match] then
          vim.bo[event.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
        end
      end,
    })

    vim.filetype.add({
      pattern = { [".*/charts?/.*templates/.*%.ya?ml"] = "helm" },
      extension = { tpl = "helm" },
    })
  end,
}

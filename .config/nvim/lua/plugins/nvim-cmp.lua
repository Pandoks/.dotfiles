return {
  "hrsh7th/nvim-cmp",
  event = "InsertEnter",
  dependencies = {
    "hrsh7th/cmp-path",
    "L3MON4D3/LuaSnip",
  },
  config = function()
    local cmp = require("cmp")
    local luasnip = require("luasnip")
    require("luasnip.loaders.from_vscode").lazy_load()
    vim.opt.completeopt = { "menu", "menuone", "noinsert", "noselect" }

    local icons = {
      Text = "󰉿",
      Method = "󰆧",
      Function = "󰊕",
      Constructor = "",
      Field = "󰜢",
      Variable = "󰀫",
      Class = "󰠱",
      Interface = "",
      Module = "",
      Property = "󰜢",
      Unit = "󰑭",
      Value = "󰎠",
      Enum = "",
      Keyword = "󰌋",
      Snippet = "",
      Color = "󰏘",
      File = "󰈙",
      Reference = "󰈇",
      Folder = "󰉋",
      EnumMember = "",
      Constant = "󰏿",
      Struct = "󰙅",
      Event = "",
      Operator = "󰆕",
      TypeParameter = "󰅲",
      Copilot = "",
    }
    vim.api.nvim_set_hl(0, "CmpItemKindCopilot", { bg = "NONE", fg = "cyan" })

    local opts = {
      completion = {
        keyword_length = 1,
      },
      snippet = {
        expand = function(args)
          luasnip.lsp_expand(args.body)
        end,
      },
      mapping = {
        ["<C-u>"] = cmp.mapping.scroll_docs(-5),
        ["<C-d>"] = cmp.mapping.scroll_docs(5),
        ["<CR>"] = cmp.mapping.confirm({
          behavior = cmp.ConfirmBehavior.Replace,
          select = false,
        }),
        ["<C-Space>"] = cmp.mapping(function()
          if cmp.visible() then
            cmp.abort()
          else
            cmp.complete()
          end
        end, { "i", "s" }),
        ["<Tab>"] = cmp.mapping(function(fallback)
          if cmp.visible() then
            cmp.select_next_item()
          elseif luasnip.expand_or_jumpable() then
            luasnip.expand_or_jump()
          else
            fallback()
          end
        end, { "i", "s" }),
        ["<S-Tab>"] = cmp.mapping(function(fallback)
          if cmp.visible() then
            cmp.select_prev_item()
          elseif luasnip.jumpable(-1) then
            luasnip.jump(-1)
          else
            fallback()
          end
        end, { "i", "s" }),
      },
      sources = cmp.config.sources({
        { name = "nvim_lsp" },
        { name = "path" },
        { name = "copilot" },
      }),
      formatting = {
        format = function(entry, vim_item)
          vim_item.kind = string.format("%s %s", icons[vim_item.kind], vim_item.kind)
          vim_item.abbr = string.sub(vim_item.abbr, 1, 30)
          return vim_item
        end,
      },
      window = {
        documentation = {
          border = "rounded",
        },
      },
      experimental = {
        ghost_text = true,
      },
      filetype = {
        { "markdown", "help" },
        enabled = false,
      },
    }

    cmp.setup(opts)
  end,
}

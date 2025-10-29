return {
  "neovim/nvim-lspconfig",
  event = { "BufReadPre", "BufNewFile" },
  dependencies = {
    "williamboman/mason-lspconfig.nvim",
    "hrsh7th/cmp-nvim-lsp",
    { "antosha417/nvim-lsp-file-operations", config = true },
    "artemave/workspace-diagnostics.nvim",
  },
  config = function()
    local signs = { Error = " ", Warn = " ", Hint = "", Info = " " }
    for type, icon in pairs(signs) do
      local hl = "DiagnosticSign" .. type
      vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = "" })
    end

    vim.diagnostic.config({
      float = {
        border = "rounded",
      },
    })

    local on_attach = function(client, bufnr)
      require("workspace-diagnostics").populate_workspace_diagnostics(client, bufnr)
      local opts = { noremap = true, silent = true, buffer = bufnr }

      opts.desc = "Show LSP references"
      vim.keymap.set("n", "<leader>fr", function()
        require("telescope.builtin").lsp_references()
      end, opts)
      opts.desc = "Show code actions"
      vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
      opts.desc = "Show documentation under cursor"
      vim.keymap.set("n", "K", function()
        vim.lsp.buf.hover({ border = "rounded" })
      end, opts)
      opts.desc = "Rename"
      vim.keymap.set("n", "<leader>r", vim.lsp.buf.rename, opts)

      -- diagnostics
      opts.desc = "Show line diagnostics"
      vim.keymap.set("n", "<leader>df", vim.diagnostic.open_float, opts)
      opts.desc = "Go to previous diagnostic"
      vim.keymap.set("n", "<leader>k", vim.diagnostic.goto_prev, opts)
      opts.desc = "Go to next diagnostic"
      vim.keymap.set("n", "<leader>j", vim.diagnostic.goto_next, opts)

      -- go tos
      opts.desc = "Go to declaration"
      vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)
      opts.desc = "Show definitions"
      vim.keymap.set("n", "gd", "<cmd>Telescope lsp_definitions<cr>", opts)
      opts.desc = "Show implementations"
      vim.keymap.set("n", "gi", "<cmd>Telescope lsp_implementations<cr>", opts)
      opts.desc = "Go to type definitions"
      vim.keymap.set("n", "gt", "<cmd>Telescope lsp_type_definitions<cr>", opts)
    end

    local capabilities = require("cmp_nvim_lsp").default_capabilities()

    local servers = {
      "svelte",
      "astro",
      "ts_ls",
      "bashls",
      "pyright",
      "clangd",
      "tailwindcss",
      "rust_analyzer",
      "dockerls",
      "docker_compose_language_service",
      "gopls",
      "zls",
    }
    for _, lsp in ipairs(servers) do
      vim.lsp.config[lsp] = {
        capabilities = capabilities,
        on_attach = on_attach,
      }
      vim.lsp.enable(lsp)
    end

    -- custom lsp configs
    vim.lsp.config.lua_ls = {
      capabilities = capabilities,
      on_attach = on_attach,
      settings = {
        Lua = {
          diagnostics = {
            globals = { "vim", "hs" },
          },
        },
      },
    }
    vim.lsp.enable("lua_ls")

    vim.lsp.config.helm_ls = {
      capabilities = capabilities,
      on_attach = on_attach,
      filetypes = { "helm" },
      settings = {
        ["helm-ls"] = {
          yamlls = { enabled = false },
        },
      },
    }
    vim.lsp.enable("helm_ls")

    vim.lsp.config.yamlls = {
      filetypes = { "yaml", "yml" },
      capabilities = capabilities,
      on_attach = on_attach,
      settings = {
        yaml = {
          format = {
            enable = false,
          },
          validate = true,
          hover = true,
          completion = true,
          schemas = {
            kubernetes = "*.yaml",
            ["http://json.schemastore.org/github-workflow"] = ".github/workflows/*",
            ["http://json.schemastore.org/github-action"] = ".github/action.{yml,yaml}",
            ["http://json.schemastore.org/ansible-stable-2.9"] = "roles/tasks/*.{yml,yaml}",
            ["http://json.schemastore.org/prettierrc"] = ".prettierrc.{yml,yaml}",
            ["http://json.schemastore.org/kustomization"] = "kustomization.{yml,yaml}",
            ["http://json.schemastore.org/ansible-playbook"] = "*play*.{yml,yaml}",
            ["http://json.schemastore.org/chart"] = "Chart.{yml,yaml}",
            ["https://json.schemastore.org/dependabot-v2"] = ".github/dependabot.{yml,yaml}",
            ["https://json.schemastore.org/gitlab-ci"] = "*gitlab-ci*.{yml,yaml}",
            ["https://raw.githubusercontent.com/OAI/OpenAPI-Specification/main/schemas/v3.1/schema.json"] = "*api*.{yml,yaml}",
            ["https://raw.githubusercontent.com/compose-spec/compose-spec/master/schema/compose-spec.json"] = "*docker-compose*.{yml,yaml}",
            ["https://raw.githubusercontent.com/argoproj/argo-workflows/master/api/jsonschema/schema.json"] = "*flow*.{yml,yaml}",
          },
        },
      },
    }
    vim.lsp.enable("yamlls")
  end,
}

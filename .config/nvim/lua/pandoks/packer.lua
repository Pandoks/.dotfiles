-- auto install packer if not installed
local ensure_packer = function()
	local fn = vim.fn
	local install_path = fn.stdpath("data") .. "/site/pack/packer/start/packer.nvim"
	if fn.empty(fn.glob(install_path)) > 0 then
		fn.system({ "git", "clone", "--depth", "1", "https://github.com/wbthomason/packer.nvim", install_path })
		vim.cmd([[packadd packer.nvim]])
		return true
	end
	return false
end
local packer_bootstrap = ensure_packer() -- true if packer was just installed

-- autocommand that reloads neovim and installs/updates/removes plugins
-- when file is saved
vim.cmd([[
  augroup packer_user_config
    autocmd!
    autocmd BufWritePost plugins-setup.lua source <afile> | PackerSync
  augroup end
]])

-- import packer safely
local status, packer = pcall(require, "packer")
if not status then
	return
end

return packer.startup(function(use)
	-- Packer can manage itself
	use("wbthomason/packer.nvim")
	use("nvim-lua/plenary.nvim")
	use("marko-cerovac/material.nvim")
	use("nvim-tree/nvim-web-devicons")
	use("nvim-lualine/lualine.nvim")
	use("lukas-reineke/indent-blankline.nvim")
	use("jose-elias-alvarez/null-ls.nvim")
	use("jay-babu/mason-null-ls.nvim")
	use("MunifTanjim/prettier.nvim")
	use("windwp/nvim-autopairs")
	use("windwp/nvim-ts-autotag")
	use("mfussenegger/nvim-dap")
	use("rcarriga/nvim-dap-ui")
	use("fgheng/winbar.nvim")
	use("kdheepak/lazygit.nvim")
	use("uga-rosa/ccc.nvim")
	use("numToStr/FTerm.nvim")
	use("laytan/cloak.nvim")
	use("lewis6991/gitsigns.nvim")
	use("kevinhwang91/promise-async")
	use("ThePrimeagen/refactoring.nvim")
	use("folke/trouble.nvim")
	use("christoomey/vim-tmux-navigator")
	use("szw/vim-maximizer")
	use("vim-scripts/ReplaceWithRegister")
	use("zbirenbaum/copilot.lua")
	use("zbirenbaum/copilot-cmp")
	use("nvim-tree/nvim-tree.lua")
	use({ "akinsho/bufferline.nvim", tag = "*", requires = "nvim-tree/nvim-web-devicons" })
	use("folke/zen-mode.nvim")
	use("nvim-neotest/neotest")
	use("nvim-neotest/neotest-python")
	use("nvim-neotest/neotest-plenary")
	use("haydenmeade/neotest-jest")
	use("olimorris/neotest-rspec")
	use("nvim-neotest/neotest-vim-test")
	use("vim-test/vim-test")

	use({
		"nvim-telescope/telescope.nvim",
		tag = "0.1.x",
	})

	use({
		"brenoprata10/nvim-highlight-colors",
		config = function()
			require("nvim-highlight-colors").setup()
		end,
	})

	use({
		"kylechui/nvim-surround",
		tag = "*", -- Use for stability; omit to use `main` branch for the latest features
		config = function()
			require("nvim-surround").setup({
				-- Configuration here, or leave empty to use defaults
			})
		end,
	})

	use({
		"numToStr/Comment.nvim",
		config = function()
			require("Comment").setup()
		end,
	})

	use({
		"nvim-treesitter/nvim-treesitter",
		run = ":TSUpdate",
	})

	use({
		"iamcco/markdown-preview.nvim",
		run = "cd app && npm install",
		setup = function()
			vim.g.mkdp_filetypes = { "markdown" }
		end,
		ft = { "markdown" },
	})

	use({
		"akinsho/git-conflict.nvim",
		tag = "*",
		config = function()
			require("git-conflict").setup()
		end,
	})

	use("theprimeagen/harpoon")
	use("mbbill/undotree")
	use("tpope/vim-fugitive")

	-- LSP
	use("neovim/nvim-lspconfig")
	use("williamboman/mason.nvim")
	use("williamboman/mason-lspconfig.nvim")
	use({ "glepnir/lspsaga.nvim", branch = "main" })
	use("onsails/lspkind.nvim")

	-- Autocompletion
	use("hrsh7th/nvim-cmp")
	use("hrsh7th/cmp-nvim-lsp")
	use("hrsh7th/cmp-buffer")
	use("hrsh7th/cmp-path")
	use("saadparwaiz1/cmp_luasnip")
	use("hrsh7th/cmp-nvim-lua")

	-- Snippets
	use("L3MON4D3/LuaSnip")
	use("rafamadriz/friendly-snippets")

	if packer_bootstrap then
		require("packer").sync()
	end
end)

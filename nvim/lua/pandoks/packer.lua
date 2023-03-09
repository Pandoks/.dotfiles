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
	use("folke/neodev.nvim")
	use("fgheng/winbar.nvim")
	use("kdheepak/lazygit.nvim")
	use("uga-rosa/ccc.nvim")
	use("numToStr/FTerm.nvim")
	use("laytan/cloak.nvim")
	use("lewis6991/gitsigns.nvim")
	use("rcarriga/nvim-notify")
	use("kevinhwang91/promise-async")
	use("ThePrimeagen/refactoring.nvim")
	use("folke/trouble.nvim")
	use("christoomey/vim-tmux-navigator")
	use("szw/vim-maximizer")
	use("vim-scripts/ReplaceWithRegister")
	use("zbirenbaum/copilot.lua")
	use("zbirenbaum/copilot-cmp")

	use("nvim-neotest/neotest")
	use("nvim-neotest/neotest-python")
	use("nvim-neotest/neotest-plenary")
	use("haydenmeade/neotest-jest")
	use("olimorris/neotest-rspec")
	use("nvim-neotest/neotest-vim-test")
	use("vim-test/vim-test")

	use({
		-- carbon file explorer
		"SidOfc/carbon.nvim",
		config = function()
			require("carbon").setup(function(settings)
				settings.compress = false
				settings.indicators = {
					collapse = "▾",
					expand = "▸",
				}

				settings.actions = vim.tbl_extend("force", settings.defaults.actions, {
					quit = "<esc>",
				})

				function settings.float_settings()
					local rows = vim.opt.lines:get()
					local height = math.floor(rows * 0.8)

					return vim.tbl_extend("force", settings.defaults.float_settings(), {
						height = height,
						row = math.floor(rows / 2 - height / 2 - 2),
					})
				end
			end)
		end,
	})

	use({
		"nvim-telescope/telescope.nvim",
		tag = "0.1.1",
		-- or                            , branch = '0.1.x',
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

	use("theprimeagen/harpoon")
	use("mbbill/undotree")
	use("tpope/vim-fugitive")

	use({
		"VonHeikemen/lsp-zero.nvim",
		branch = "v2.x",
		requires = {
			-- LSP Support
			{ "neovim/nvim-lspconfig" }, -- Required
			{ "williamboman/mason.nvim" }, -- Optional
			{ "williamboman/mason-lspconfig.nvim" }, -- Optional

			-- Autocompletion
			{ "hrsh7th/nvim-cmp" }, -- Required
			{ "hrsh7th/cmp-nvim-lsp" }, -- Required
			{ "hrsh7th/cmp-buffer" }, -- Optional
			{ "hrsh7th/cmp-path" }, -- Optional
			{ "saadparwaiz1/cmp_luasnip" }, -- Optional
			{ "hrsh7th/cmp-nvim-lua" }, -- Optional

			-- Snippets
			{ "L3MON4D3/LuaSnip" }, -- Required
			{ "rafamadriz/friendly-snippets" }, -- Optional
		},
	})

	if packer_bootstrap then
		require("packer").sync()
	end
end)

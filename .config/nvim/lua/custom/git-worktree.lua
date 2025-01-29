local M = {}
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local conf = require("telescope.config").values
local action_state = require("telescope.actions.state")
local actions = require("telescope.actions")

local function is_git_repo()
  local handle = io.popen("git rev-parse --is-inside-work-tree 2>/dev/null")
  if handle == nil then
    return false
  end
  local result = handle:read("*a")
  handle:close()
  return result ~= ""
end

local function get_git_worktrees()
  local handle = io.popen("git worktree list --porcelain")
  if handle == nil then
    return {}
  end

  local result = handle:read("*a")
  handle:close()

  local worktrees = {}
  local current_worktree = {}

  for line in result:gmatch("[^\r\n]+") do
    if line:match("^worktree") then
      if current_worktree.path then
        table.insert(worktrees, current_worktree)
      end
      current_worktree = {
        path = line:match("^worktree (.+)"),
      }
    elseif line:match("^branch") then
      local branch = line:match("^branch (.+)")
      current_worktree.branch = branch:gsub("refs/heads/", "")
    end
  end

  if current_worktree.path then
    table.insert(worktrees, current_worktree)
  end

  return worktrees
end

function M.goto_git_worktree()
  if not is_git_repo() then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  local worktrees = get_git_worktrees()

  if #worktrees == 0 then
    vim.notify("No git worktrees found", vim.log.levels.ERROR)
    return
  end

  pickers
    .new({}, {
      prompt_title = "Git Worktrees",
      finder = finders.new_table({
        results = worktrees,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.branch .. " - " .. entry.path,
            ordinal = entry.branch .. " " .. entry.path,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          vim.cmd("cd " .. selection.value.path)
        end)
        return true
      end,
    })
    :find()
end

vim.api.nvim_create_user_command("GoToWorktree", M.goto_git_worktree, {})

vim.keymap.set("n", "<leader>w", M.goto_git_worktree, { desc = "Go to Git Worktree" })

return M

goto-directories() {
  selected=$(find . \( -name .git -o -name node_modules \) -prune -o -type d -print | fzf)

  if [[ -z $selected ]]; then
    return
  fi
  cd $selected
}

find-open() {
  local home_ignore_file="$HOME/.fzfignore"
  local directory_ignore_file="$(pwd)/.fzfignore"

  if [[ -f $directory_ignore_file ]]; then
    selected=$(find -L . -type f -print | grep -vFf $directory_ignore_file | fzf)
  elif [[ -f $home_ignore_file ]]; then
    selected=$(find -L . -type f -print | grep -vFf $home_ignore_file | fzf)
  else
    selected=$(find -L . -type f -print | fzf)
  fi

  if [[ -z $selected ]]; then
    return
  fi
  nvim $selected
}

goto-git() {
  base_git_dir=$(git rev-parse --show-toplevel)

  ignored_dirs=(.git node_modules .sst)
  ignore_conditions=""
  for dir in "${ignored_dirs[@]}"; do
    if [[ -z "$ignore_conditions" ]]; then
      ignore_conditions="-name $dir"
    else
      ignore_conditions="$ignore_conditions -o -name $dir"
    fi
  done

  selected=$(
    eval "find $base_git_dir \( $ignore_conditions \) -prune -o -type d -print" |
      sed "s|^$base_git_dir/||" |
      fzf
  )

  if [[ -z $selected ]]; then
    return
  fi
  cd "$base_git_dir/$selected" 2>/dev/null || cd $selected
}

tmux-sessionizer() {
  if [[ $# -eq 1 ]]; then
    selected=$1
  else
    search_dirs=(~ ~/Projects ~/Projects/examples ~/.config)
    selected=$(find -L "${search_dirs[@]}" -mindepth 1 -maxdepth 1 -type d | fzf)
  fi

  if [[ -z $selected ]]; then
    return
  fi

  selected_name=$(basename "$selected" | tr . _)
  tmux_running=$(pgrep tmux)

  if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
    tmux new-session -s "$selected_name" -c "$selected"
    exit 0
  fi

  if ! tmux has-session -t="$selected_name" 2>/dev/null; then
    tmux new-session -ds "$selected_name" -c "$selected"
  fi

  tmux switch-client -t "$selected_name"
}

goto-git-worktree() {
  base_git_dir=$(git rev-parse --show-toplevel)

  worktrees=$(git worktree list --porcelain | awk '
    /^worktree/ {worktree=$2}
    /^branch/ {branch=$2; sub("refs/heads/", "", branch); print branch " - \033[90m" worktree "\033[0m"}
  ')

  selected=$(echo "$worktrees" | fzf --ansi)

  if [ -n "$selected" ]; then
    worktree_path=$(echo "$selected" | awk -F ' - ' '{print $2}')
    cd "$worktree_path"
  fi
  return
}
alias gtw="goto-git-worktree"

bindkey -s ^t "goto-directories\n"
bindkey -s ^o "find-open\n"
bindkey -s ^g "goto-git\n"
bindkey -s ^f "tmux-sessionizer\n"
bindkey -s ^w "goto-git-worktree\n"

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

kube-context-switcher() {
  current_context=$(kubectl config current-context 2>/dev/null)
  current_cluster=$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null)

  prompt="Select Kubernetes Context: "

  header=''
  if [[ -n $current_cluster ]]; then
    header="Current cluster: $current_cluster"
  fi

  contexts_with_clusters=$(kubectl config view -o jsonpath='{range .contexts[*]}{.name}{"\t"}{.context.cluster}{"\n"}{end}' 2>/dev/null)

  if [[ -z $contexts_with_clusters ]]; then
    echo "No Kubernetes contexts found." >&2
    return 1
  fi

  selected_line=$(
    printf "%s\n" "$contexts_with_clusters" |
      fzf --prompt="$prompt" --header="$header" --delimiter=$'\t' --with-nth=1
  )

  if [[ -z $selected_line ]]; then
    return
  fi

  selected_context=$(printf "%s" "$selected_line" | cut -f1)
  selected_cluster=$(printf "%s" "$selected_line" | cut -f2)

  if kubectl config use-context "$selected_context" >/dev/null; then
    echo "Switched to context: $selected_context"
    if [[ -n $selected_cluster ]]; then
      echo "Cluster: $selected_cluster"
    fi
  else
    echo "Failed to switch Kubernetes context." >&2
    return 1
  fi
}

bindkey -s ^t "goto-directories\n"
bindkey -s ^o "find-open\n"
bindkey -s ^g "goto-git\n"
bindkey -s ^f "tmux-sessionizer\n"
bindkey -s ^w "goto-git-worktree\n"

alias ks=kube-context-switcher

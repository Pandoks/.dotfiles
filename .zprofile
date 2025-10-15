eval "$(/opt/homebrew/bin/brew shellenv)"

# Ensure login shells invoked as commands still load interactive config
if [[ -n $ZSH_VERSION && $- != *i* && -t 0 ]]; then
  source "$HOME/.zshrc"
fi

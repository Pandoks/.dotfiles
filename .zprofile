if [[ -x /opt/homebrew/bin/brew ]]; then # Apple Silicon Homebrew path.
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then # Intel Mac Homebrew path.
  eval "$(/usr/local/bin/brew shellenv)"
fi

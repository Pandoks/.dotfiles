# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# If you come from bash you might have to change your $PATH.
# export PATH=$HOME/bin:/usr/local/bin:$PATH

# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load --- if set to "random", it will
# load a random theme each time oh-my-zsh is loaded, in which case,
# to know which specific one was loaded, run: echo $RANDOM_THEME
# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
# ZSH_THEME="robbyrussell"

# Set list of themes to pick from when loading at random
# Setting this variable when ZSH_THEME=random will cause zsh to load
# a theme from this variable instead of looking in $ZSH/themes/
# If set to an empty array, this variable will have no effect.
# ZSH_THEME_RANDOM_CANDIDATES=( "robbyrussell" "agnoster" )

# Uncomment the following line to use case-sensitive completion.
# CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion.
# Case-sensitive completion must be off. _ and - will be interchangeable.
# HYPHEN_INSENSITIVE="true"

# Uncomment one of the following lines to change the auto-update behavior
# zstyle ':omz:update' mode disabled  # disable automatic updates
# zstyle ':omz:update' mode auto      # update automatically without asking
zstyle ':omz:update' mode reminder  # just remind me to update when it's time

# Uncomment the following line to change how often to auto-update (in days).
# zstyle ':omz:update' frequency 13

# Uncomment the following line if pasting URLs and other text is messed up.
# DISABLE_MAGIC_FUNCTIONS="true"

# Uncomment the following line to disable colors in ls.
# DISABLE_LS_COLORS="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
# ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
# You can also set it to another string to have that shown instead of the default red dots.
# e.g. COMPLETION_WAITING_DOTS="%F{yellow}waiting...%f"
# Caution: this setting can cause issues with multiline prompts in zsh < 5.7.1 (see #5765)
# COMPLETION_WAITING_DOTS="true"

# Uncomment the following line if you want to disable marking untracked files
# under VCS as dirty. This makes repository status check for large repositories
# much, much faster.
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# Uncomment the following line if you want to change the command execution time
# stamp shown in the history command output.
# You can set one of the optional three formats:
# "mm/dd/yyyy"|"dd.mm.yyyy"|"yyyy-mm-dd"
# or set a custom format using the strftime function format specifications,
# see 'man strftime' for details.
# HIST_STAMPS="mm/dd/yyyy"

# Would you like to use another custom folder than $ZSH/custom?
# ZSH_CUSTOM=/path/to/new-custom-folder

# Which plugins would you like to load?
# Standard plugins can be found in $ZSH/plugins/
# Custom plugins may be added to $ZSH_CUSTOM/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
plugins=(git zsh-vi-mode)
ZVM_CURSOR_STYLE_ENABLED=false
function zvm_after_init() {
  # Fuzzy finding key bindings for initial load
  [ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
  [ -f /opt/homebrew/opt/fzf/shell/completion.zsh ] && source /opt/homebrew/opt/fzf/shell/completion.zsh
  [ -f /opt/homebrew/opt/fzf/shell/key-bindings.zsh ] && source /opt/homebrew/opt/fzf/shell/key-bindings.zsh
}

source $ZSH/oh-my-zsh.sh

# User configuration

# export MANPATH="/usr/local/man:$MANPATH"

# You may need to manually set your language environment
# export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
else
  export EDITOR='nvim'
fi

# Use Vi keybindings for navigation
# bindkey -v

# Compilation flags
# export ARCHFLAGS="-arch x86_64"

# Set personal aliases, overriding those provided by oh-my-zsh libs,
# plugins, and themes. Aliases can be placed here, though oh-my-zsh
# users are encouraged to define aliases within the ZSH_CUSTOM folder.
# For a full list of active aliases, run `alias`.
#
# Example aliases
# alias zshconfig="mate ~/.zshrc"
# alias ohmyzsh="mate ~/.oh-my-zsh"

# General aliases
alias c=clear

# Editor aliases
alias vim=nvim
alias pvim="uv run nvim"

# Lazy git alias
alias lg=lazygit

# Check localhost servers
alias lsports='lsof -i -P -n | grep LISTEN'

# Homebrew aliases
alias b='arch -arm64 brew'
bu() {
  b update
  b upgrade
  b cu -a -y --include-mas
  b autoremove
  b cleanup
  b doctor
  omz update
  clear
  fastfetch
}
bi() {
  b install "$1"
  echo 'Updating Brewfile...'
  b bundle dump --force --file=~/Brewfile
  echo 'Brewfile updated'
}
bU() {
  b uninstall --zap --force "$1"
  echo 'Updating Brewfile...'
  b bundle dump --force --file=~/Brewfile
  echo 'Brewfile updated'
}

# tmux aliases
alias tm=tmux

# yarn aliases
alias y=yarn
alias yean='rm -rf yarn.lock **/node_modules'

# opencode
alias code=opencode

# powerlevel10k theme sourcing
source /opt/homebrew/share/powerlevel10k/powerlevel10k.zsh-theme

####   Language path updates   ####
# ruby (don't need to install ruby directly)
eval "$(rbenv init - zsh)"

# node version manager
export NVM_DIR="$HOME/.nvm"
[ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"  # This loads nvm
[ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"  # This loads nvm bash_completion

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# local script paths
export PATH="/Users/pandoks/.local/bin:$PATH"

# Fuzzy finding key bindings for after load
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
source "/opt/homebrew/opt/fzf/shell/completion.zsh"
source "/opt/homebrew/opt/fzf/shell/key-bindings.zsh"

# pnpm
export PNPM_HOME="/Users/pandoks/Library/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
# pnpm end

# curl
export PATH="/opt/homebrew/opt/curl/bin:$PATH"

# aws
alias aws='aws --profile pandoks'

# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('/opt/homebrew/Caskroom/miniconda/base/bin/conda' 'shell.zsh' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "/opt/homebrew/Caskroom/miniconda/base/etc/profile.d/conda.sh" ]; then
        . "/opt/homebrew/Caskroom/miniconda/base/etc/profile.d/conda.sh"
    else
        export PATH="/opt/homebrew/Caskroom/miniconda/base/bin:$PATH"
    fi
fi
unset __conda_setup
# <<< conda initialize <<<

# tabtab source for electron-forge package
# uninstall by removing these lines or running `tabtab uninstall electron-forge`
[[ -f /Users/pandoks/Projects/whisper/node_modules/tabtab/.completions/electron-forge.zsh ]] && . /Users/pandoks/Projects/whisper/node_modules/tabtab/.completions/electron-forge.zsh
export PATH="/opt/homebrew/opt/pnpm@8/bin:$PATH"

encrypt() {
  local fileName="$1"
  openssl enc -aes-256-cbc -pbkdf2 -in $1 -out "${fileName%.*}.enc"
  printf "Delete original file? [y/n] "
  read answer
  if [[ $answer == "y" || $answer == "Y" ]]; then
    rm -rf $fileName
  fi
}
decrypt() {
  local fileName="$1"
  openssl enc -d -aes-256-cbc -pbkdf2 -in $1 -out "${fileName%.*}.zk"
  printf "Delete encrypted file? [y/n] "
  read answer
  if [[ $answer == "y" || $answer == "Y" ]]; then
    rm -rf $fileName
  fi
}

export JAVA_HOME=/Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=$PATH:$ANDROID_HOME/emulator
export PATH=$PATH:$ANDROID_HOME/platform-tools
export XDG_CONFIG_HOME="$HOME/.config"

source ~/.secrets

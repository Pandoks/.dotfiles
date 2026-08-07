#!/bin/sh

set -eu

command -v jq > /dev/null 2>&1 || { printf '[%s]' "$(basename "$PWD")"; exit 0; }

has_git=""
command -v git > /dev/null 2>&1 && has_git=1

payload="$(cat)" # CC pipes json to stdin which cat captures into `payload` variable

field() { printf '%s' "$payload" | jq -r "$1 // empty" 2> /dev/null || true; }

cwd="$(field '.workspace.current_dir')"
model="$(field '.model.display_name // .model.id')"
effort="$(field '.effort.level')"
style="$(field '.output_style.name')"
ctx_pct="$(field '.context_window.used_percentage')"
cost="$(field '.cost.total_cost_usd')"
rl5h="$(field '.rate_limits.five_hour.used_percentage')"
rl7d="$(field '.rate_limits.seven_day.used_percentage')"

dir="$(basename "${cwd:-$PWD}")"

branch=""
if [ -n "$has_git" ] && [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch_name="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2> /dev/null || true)"
  if git -C "$cwd" diff --quiet 2> /dev/null && git -C "$cwd" diff --cached --quiet 2> /dev/null; then
    branch="$branch_name"
  else
    branch="$branch_name*"
  fi
fi

out="[$dir]"
[ -n "$branch" ] && out="$out ($branch)"
[ -n "$model" ] && out="$out $model"
[ -n "$effort" ] && out="$out @$effort"
[ -n "$style" ] && [ "$style" != "default" ] && out="$out · $style"

extras=""
[ -n "$ctx_pct" ] && extras="$extras session: ${ctx_pct%.*}%"
[ -n "$cost" ] && extras="$extras \$$(printf '%.2f' "$cost" 2> /dev/null || printf '%s' "$cost")"
[ -n "$rl5h" ] && extras="$extras · 5h:${rl5h%.*}%"
[ -n "$rl7d" ] && extras="$extras 7d:${rl7d%.*}%"

[ -n "$extras" ] && out="$out ·$extras" # extras starts with a space

printf '%s' "$out"

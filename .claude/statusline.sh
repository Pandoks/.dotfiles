#!/bin/sh

set -eu

JQ="$(command -v jq || true)"
[ -z "$JQ" ] && {
  printf '[%s]' "$(basename "$PWD")"
  exit 0
}

payload="$(cat)"
jqf() { printf '%s' "$payload" | "$JQ" -r "$1 // empty" 2> /dev/null || true; }

cwd="$(jqf '.workspace.current_dir')"
model="$(jqf '.model.display_name // .model.id')"
effort="$(jqf '.effort.level')"
style="$(jqf '.output_style.name')"
ctx_pct="$(jqf '.context_window.used_percentage')"
cost="$(jqf '.cost.total_cost_usd')"
rl5h="$(jqf '.rate_limits.five_hour.used_percentage')"
rl7d="$(jqf '.rate_limits.seven_day.used_percentage')"

dir="$(basename "${cwd:-$PWD}")"

branch=""
if [ -n "$cwd" ] && /usr/bin/git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch="$(/usr/bin/git -C "$cwd" rev-parse --abbrev-ref HEAD 2> /dev/null || true)"
  if ! /usr/bin/git -C "$cwd" diff --quiet 2> /dev/null || ! /usr/bin/git -C "$cwd" diff --cached --quiet 2> /dev/null; then
    branch="${branch}*"
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

[ -n "$extras" ] && out="$out ·$extras"

printf '%s' "$out"

#!/bin/sh

set -eu

# Off Claude models (RED-SNOW), drop the subagent's `model` so it inherits the session's model.
payload="$(cat)"
transcript="$(printf '%s' "$payload" | jq -r .transcript_path)"
model="$(grep -F '"type":"api-request"' "$transcript" | tail -n 1 | jq -r .params.model)" || model=""
case "$model" in claude-*) exit 0 ;; esac
printf '%s' "$payload" | jq '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input | del(.model))}}'

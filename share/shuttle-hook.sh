#!/bin/bash
# Shuttle Hook - Captures Claude Code events for activity tracking
#
# Writes events to ~/.shuttle/events.jsonl for the Shuttle daemon
# (WaitingTracker, SentFiles). Tracks working/idle status based on Claude
# activity. The event shape is identical to the legacy portolan-hook.sh so the
# Elixir readers parse it unchanged; Shuttle's readers prefer this path and fall
# back to the Portolan path when this file is absent.
#
# Install: register in ~/.claude/settings.json so every Claude Code hook event
# runs this script (see AGENTS.md "Owning the event stream" / `make install-hook`).

set -e

# Config
SHUTTLE_DATA_DIR="${SHUTTLE_DATA_DIR:-$HOME/.shuttle}"
EVENTS_FILE="${SHUTTLE_EVENTS_FILE:-$SHUTTLE_DATA_DIR/events.jsonl}"
mkdir -p "$(dirname "$EVENTS_FILE")"

# Find jq
JQ=$(command -v jq 2>/dev/null || echo "/opt/homebrew/bin/jq")
[ ! -x "$JQ" ] && JQ="/usr/local/bin/jq"
[ ! -x "$JQ" ] && exit 0  # Skip silently if no jq

# Read input
input=$(cat)

hook_event_name=$("$JQ" -r '.hook_event_name // "unknown"' <<< "$input")
session_id=$("$JQ" -r '.session_id // "unknown"' <<< "$input")
cwd=$("$JQ" -r '.cwd // ""' <<< "$input")

# Get tmux session
tmux_session=""
[ -n "$TMUX" ] && tmux_session=$(tmux display-message -p '#S' 2>/dev/null || echo "")

# Timestamp in ms — perl Time::HiRes (macOS-safe) when available, else seconds*1000.
# A tracking hook must never hard-fail the session: guard so a missing Time::HiRes
# (e.g. on HPC login nodes whose Perl lacks it) can't abort the hook under `set -e`.
timestamp=$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000' 2>/dev/null) || timestamp=""
[ -z "$timestamp" ] && timestamp=$(($(date +%s) * 1000))
event_id="${session_id}-${timestamp}-${RANDOM}"

# Map event type
case "$hook_event_name" in
  PreToolUse)       event_type="pre_tool_use" ;;
  PostToolUse)      event_type="post_tool_use" ;;
  Stop)             event_type="stop" ;;
  SubagentStop)     event_type="subagent_stop" ;;
  SessionStart)     event_type="session_start" ;;
  SessionEnd)       event_type="session_end" ;;
  UserPromptSubmit) event_type="user_prompt_submit" ;;
  Notification)     event_type="notification" ;;
  *)                exit 0 ;;  # Ignore unknown events
esac

# Extract tool info for tool events
tool_name=$("$JQ" -r '.tool_name // empty' <<< "$input")
tool_input=$("$JQ" -c '.tool_input // null' <<< "$input")

# Build canonical event JSON. PostToolUse joins the same JSONL path as
# PreToolUse so local and remote tailers see one event shape.
if [ -n "$tool_name" ]; then
  event=$("$JQ" -n -c \
    --arg id "$event_id" \
    --argjson timestamp "$timestamp" \
    --arg type "$event_type" \
    --arg sessionId "$session_id" \
    --arg cwd "$cwd" \
    --arg tmuxSession "$tmux_session" \
    --arg harness "claude-code" \
    --arg origin "$(hostname)" \
    --arg tool "$tool_name" \
    --argjson toolInput "$tool_input" \
    '(($toolInput.file_path // $toolInput.path // $toolInput.filePath // ($toolInput.files // [])[0]) // null) as $file_path |
     {id: $id, timestamp: $timestamp, type: $type, sessionId: $sessionId, cwd: $cwd, tmuxSession: $tmuxSession, harness: $harness, originName: $origin, tool: $tool, toolInput: (
       if ($file_path | type) == "string" and ($file_path | length) > 0
       then $toolInput + { file_path: $file_path }
       else $toolInput
       end
     )}')
else
  event=$("$JQ" -n -c \
    --arg id "$event_id" \
    --argjson timestamp "$timestamp" \
    --arg type "$event_type" \
    --arg sessionId "$session_id" \
    --arg cwd "$cwd" \
    --arg tmuxSession "$tmux_session" \
    --arg harness "claude-code" \
    --arg origin "$(hostname)" \
    '{id: $id, timestamp: $timestamp, type: $type, sessionId: $sessionId, cwd: $cwd, tmuxSession: $tmuxSession, harness: $harness, originName: $origin}')
fi

# Append to file
echo "$event" >> "$EVENTS_FILE"

exit 0

#!/bin/sh
#
# LLM Pulse — Claude Code usage bridge
#
# Claude Code hands its status line command a JSON payload on stdin, and that
# payload carries the account's own rate-limit state:
#
#   rate_limits.five_hour.{used_percentage, resets_at}
#   rate_limits.seven_day.{used_percentage, resets_at}
#
# Those reset times are the vendor's own, parsed from the response headers —
# not a guess. The desktop app receives the same values but writes only the
# percentages to its history file, so without this bridge LLM Pulse has to
# infer reset times from percentage collapses, and cannot infer them at all
# for a window that opened while the desktop app was closed.
#
# This copies those four numbers, plus the moment it saw them, into LLM
# Pulse's own directory. It reads nothing else out of the payload: not the
# session id, not the workspace path, not the model, not a line of the
# transcript.
#
# Install by adding this to ~/.claude/settings.json — LLM Pulse never writes
# that file itself:
#
#   "statusLine": {
#     "type": "command",
#     "command": "/bin/sh '/Applications/LLM Pulse.app/Contents/Resources/usage-bridge.sh'",
#     "refreshInterval": 30
#   }
#
# Delete it and LLM Pulse falls back to the desktop app's history file.
#
# The setting holds exactly one command, so if you already have a status line,
# put it in LLM_PULSE_STATUSLINE_CHAIN and it renders instead of the summary
# below; that is the only way to keep both.

set -u
umask 077

payload=$(cat)

limits=$(
    printf '%s' "$payload" \
        | /usr/bin/plutil -extract rate_limits json -o - -- - 2>/dev/null
) || limits=''

# Absent until the first API response of a session, and permanently absent on
# API-key, Bedrock and Vertex auth. Neither is an error worth reporting into
# somebody's prompt.
if [ -n "$limits" ] && [ "$limits" != 'null' ]; then
    directory="$HOME/Library/Application Support/LLM Pulse"
    destination="$directory/claude-cli-usage.json"
    if mkdir -p "$directory" 2>/dev/null; then
        # Write beside the destination and rename: LLM Pulse polls this file
        # several times a second and must never catch a half-written one.
        scratch="$destination.$$"
        if printf '{"observedAt":%s,"rateLimits":%s}\n' "$(date +%s)" "$limits" \
            > "$scratch" 2>/dev/null
        then
            mv -f "$scratch" "$destination" 2>/dev/null || rm -f "$scratch"
        else
            rm -f "$scratch"
        fi
    fi
fi

# Whatever happened above, a status line still has to render. A non-zero exit
# or an error on stdout would put this script's problems into the prompt of
# every session, which is not what a passive monitor is for.
if [ -n "${LLM_PULSE_STATUSLINE_CHAIN:-}" ]; then
    printf '%s' "$payload" | sh -c "$LLM_PULSE_STATUSLINE_CHAIN" 2>/dev/null
    exit 0
fi

field() {
    printf '%s' "$limits" \
        | /usr/bin/plutil -extract "$1" raw -o - -- - 2>/dev/null
}

five=$(field five_hour.used_percentage)
seven=$(field seven_day.used_percentage)
separator=''
if [ -n "${five:-}" ]; then
    printf '5h %s%%' "$five"
    separator=' · '
fi
if [ -n "${seven:-}" ]; then
    printf '%s7d %s%%' "$separator" "$seven"
fi
printf '\n'

exit 0

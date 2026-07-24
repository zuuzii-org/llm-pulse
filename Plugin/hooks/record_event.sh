#!/bin/sh

# LLM Pulse observes Codex lifecycle events without changing hook decisions.
# This wrapper intentionally depends only on tools bundled with macOS.

record_event() {
    # `CDPATH=` is a one-command environment assignment, not a typo: a CDPATH
    # inherited from the user's shell would make `cd` resolve somewhere else
    # and print the directory it chose.
    # shellcheck disable=SC1007
    script_directory=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" 2>/dev/null && pwd -P)
    [ -n "$script_directory" ] || return
    [ -r "$script_directory/record_event.js" ] || return

    event=$(/usr/bin/osascript -l JavaScript \
        "$script_directory/record_event.js" 2>/dev/null)
    [ -n "$event" ] || return

    application_directory="$HOME/Library/Application Support/LLM Pulse"
    events_directory="$application_directory/events"
    events_file="$events_directory/events.jsonl"
    lock_directory="$events_directory/.write-lock"
    maximum_journal_bytes=8388608

    # Never follow a user-controlled symlink into another location.
    [ ! -L "$application_directory" ] || return
    [ ! -L "$events_directory" ] || return

    umask 077
    /bin/mkdir -p "$events_directory" 2>/dev/null || {
        return
    }
    /bin/chmod 700 "$application_directory" "$events_directory" 2>/dev/null

    attempt=0
    while ! /bin/mkdir "$lock_directory" 2>/dev/null; do
        attempt=$((attempt + 1))
        if [ "$attempt" -eq 1 ] && [ -d "$lock_directory" ]; then
            lock_modified=$(/usr/bin/stat -f %m "$lock_directory" 2>/dev/null)
            current_time=$(/bin/date +%s)
            if [ -n "$lock_modified" ] &&
                [ $((current_time - lock_modified)) -gt 10 ]; then
                /bin/rmdir "$lock_directory" 2>/dev/null
                continue
            fi
        fi
        [ "$attempt" -lt 100 ] || return
        /bin/sleep 0.01
    done

    cleanup_lock() {
        /bin/rmdir "$lock_directory" 2>/dev/null
    }
    trap cleanup_lock EXIT HUP INT TERM

    [ ! -L "$events_file" ] || return
    if [ -e "$events_file" ] && [ ! -f "$events_file" ]; then
        return
    fi

    current_bytes=0
    if [ -f "$events_file" ]; then
        current_bytes=$(/usr/bin/wc -c < "$events_file" 2>/dev/null)
    fi
    event_bytes=$(/usr/bin/printf '%s\n' "$event" | /usr/bin/wc -c)
    if [ $((current_bytes + event_bytes)) -gt "$maximum_journal_bytes" ]; then
        compacted_file=$(/usr/bin/mktemp "$events_directory/.compact.XXXXXX") || return
        if /usr/bin/tail -c "$maximum_journal_bytes" "$events_file" 2>/dev/null | \
            /usr/bin/osascript -l JavaScript \
                "$script_directory/record_event.js" --compact \
                > "$compacted_file" 2>/dev/null; then
            /bin/chmod 600 "$compacted_file" 2>/dev/null
            /bin/mv -f "$compacted_file" "$events_file" 2>/dev/null || {
                /bin/rm -f "$compacted_file"
                return
            }
        else
            /bin/rm -f "$compacted_file"
            return
        fi
    fi

    /usr/bin/printf '%s\n' "$event" >> "$events_file" 2>/dev/null || return
    /bin/chmod 600 "$events_file" 2>/dev/null

    cleanup_lock
    trap - EXIT HUP INT TERM
}

record_event
/usr/bin/printf '{}\n'
exit 0

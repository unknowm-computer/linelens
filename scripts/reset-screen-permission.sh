#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$task_root/dist/LineLens.app"
if [[ "${1:-}" != "" && "${1:-}" != "--relaunch" ]]; then
    printf 'Usage: %s [--relaunch]\n' "$0" >&2
    exit 1
fi

# Reset only this app's screen-capture approval; leave all other services and apps intact.
while read -r task_pid task_executable; do
    if [[ "$task_executable" == "$app_dir/Contents/MacOS/LineLens" ]]; then
        kill -TERM "$task_pid"
        for ((task_attempt = 0; task_attempt < 50; task_attempt++)); do
            if ! kill -0 "$task_pid" 2>/dev/null; then break; fi
            sleep 0.1
        done
        if kill -0 "$task_pid" 2>/dev/null; then
            printf 'LineLens did not quit; permission was not reset.\n' >&2
            exit 1
        fi
    fi
done < <(ps -axo pid=,comm=)

/usr/bin/tccutil reset ScreenCapture com.linelens.app
printf 'LineLens 화면 기록 승인 연결을 초기화했습니다. 현재 앱에서 다시 허용해 주세요.\n'
if [[ "${1:-}" == "--relaunch" ]]; then /usr/bin/open "$app_dir"; fi

#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$task_root/scripts/sparkle-tools.sh"
tools_dir="$(sparkle_tools_dir)"
config="$task_root/Resources/Info.plist"
expected_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$config" 2>/dev/null || true)"
if [[ -n "$expected_key" ]]; then
    verify_sparkle_key "$tools_dir" "$config"
    printf '기존 Sparkle 키 확인 완료. 공개 키·개인 키를 변경하지 않았습니다.\n'
else
    "$tools_dir/generate_keys" --account com.linelens.app
    public_key="$("$tools_dir/generate_keys" --account com.linelens.app -p)"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $public_key" "$config"
    printf 'Sparkle 공개 키를 Info.plist에 고정했습니다. 개인 키는 로그인 키체인에 보관됩니다.\n'
fi

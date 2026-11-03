#!/bin/bash

# Source this file from build/release scripts. SwiftPM verifies the pinned artifact checksum.
sparkle_tools_dir() {
    local task_root
    task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local tools_dir="$task_root/.build/artifacts/sparkle/Sparkle/bin"
    if [[ ! -x "$tools_dir/generate_keys" || ! -x "$tools_dir/generate_appcast" || ! -x "$tools_dir/sign_update" ]]; then
        (cd "$task_root" && swift package resolve) >&2 || return 1
    fi
    [[ -x "$tools_dir/generate_keys" && -x "$tools_dir/generate_appcast" && -x "$tools_dir/sign_update" ]] || return 1
    printf '%s\n' "$tools_dir"
}

verify_sparkle_key() {
    local tools_dir="$1" config="$2" expected_key actual_key
    expected_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$config")" || return 1
    actual_key="$("$tools_dir/generate_keys" --account com.linelens.app -p)" || {
        printf 'Sparkle 개인 키가 없습니다. 기존 키를 가져오세요. 새 키로 대체하지 않습니다.\n' >&2
        return 1
    }
    if [[ "$expected_key" != "$actual_key" ]]; then
        printf 'Sparkle 키가 앱의 고정 공개 키와 다릅니다. 배포를 중단합니다.\n' >&2
        return 1
    fi
}

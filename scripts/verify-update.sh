#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ne 2 ]]; then
    printf 'Usage: %s PREVIOUS.app UPDATE.app\n' "$0" >&2
    exit 1
fi
previous_app="$1"
update_app="$2"
identity_config="$task_root/Resources/SigningIdentity.plist"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :BundleIdentifier' "$identity_config")"
fingerprint="$(/usr/libexec/PlistBuddy -c 'Print :CertificateSHA1' "$identity_config")"
if [[ ! "$fingerprint" =~ ^[A-F0-9]{40}$ ]]; then
    printf '프로젝트의 고정 인증서 지문이 유효하지 않습니다.\n' >&2; exit 1
fi
requirement="identifier \"$bundle_identifier\" and certificate leaf = H\"$fingerprint\""
for task_app in "$previous_app" "$update_app"; do
    if [[ ! -f "$task_app/Contents/Info.plist" ]]; then
        printf '앱을 찾을 수 없습니다: %s\n' "$task_app" >&2; exit 1
    fi
    task_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_app/Contents/Info.plist")"
    if [[ "$task_identifier" != "$bundle_identifier" ]]; then
        printf '앱의 Bundle ID가 다릅니다: %s\n' "$task_app" >&2; exit 1
    fi
    codesign --verify --all-architectures --deep --strict -R="$requirement" "$task_app"
done
previous_requirement="$(codesign -d -r- "$previous_app" 2>&1 | sed -n 's/^designated => //p')"
if [[ -z "$previous_requirement" || "$previous_requirement" == *cdhash* ]]; then
    printf '이전 배포본에 유지 가능한 서명 신원이 없습니다.\n' >&2; exit 1
fi
codesign --verify --all-architectures --deep --strict -R="$previous_requirement" "$update_app"
previous_update_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$previous_app/Contents/Info.plist" 2>/dev/null || true)"
new_update_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$update_app/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "$new_update_key" ]]; then
    swift "$task_root/scripts/verify-sparkle.swift" "$update_app/Contents/Info.plist"
fi
if [[ -n "$previous_update_key" && "$previous_update_key" != "$new_update_key" ]]; then
    printf 'Sparkle 공개 키가 이전 앱과 다릅니다. 기존 업데이트 신뢰 연결을 유지하세요.\n' >&2
    exit 1
fi
previous_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$previous_app/Contents/Info.plist")"
update_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$update_app/Contents/Info.plist")"
if [[ ! "$previous_build" =~ ^[1-9][0-9]{0,8}$ || ! "$update_build" =~ ^[1-9][0-9]{0,8}$ ]] ||
   (( update_build <= previous_build )); then
    printf '업데이트 빌드 번호가 이전보다 커야 합니다: %s -> %s\n' "$previous_build" "$update_build" >&2
    exit 1
fi
printf '업데이트 서명 검증 성공: %s, build %s -> %s\n' "$bundle_identifier" "$previous_build" "$update_build"
printf '인증서 SHA-1: %s\n' "$fingerprint"
printf '기존 앱의 서명 요구조건을 새 앱의 모든 아키텍처가 만족합니다.\n'

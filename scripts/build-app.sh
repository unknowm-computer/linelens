#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
configuration=release
output_dir="$task_root/dist"
app_version=""
build_number=""
universal=0
usage() {
    printf 'Usage: %s [debug|release] [--universal] [--version X.Y.Z] [--build-number N] [--output-dir DIRECTORY]\n' "$0"
}
if [[ "${1:-}" == "debug" || "${1:-}" == "release" ]]; then configuration="$1"; shift; fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        --universal) universal=1; shift ;;
        --version|--build-number|--output-dir)
            if [[ $# -lt 2 || -z "$2" ]]; then usage >&2; exit 1; fi
            case "$1" in
                --version) app_version="$2" ;;
                --build-number) build_number="$2" ;;
                --output-dir) output_dir="$2" ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
if [[ -n "$app_version" && ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '버전은 X.Y.Z 형식이어야 합니다.\n' >&2; exit 1
fi
if [[ -n "$build_number" && ! "$build_number" =~ ^[1-9][0-9]{0,8}$ ]]; then
    printf '빌드 번호는 1~999999999 사이의 정수여야 합니다.\n' >&2; exit 1
fi
swift "$task_root/scripts/verify-sparkle.swift" "$task_root/Resources/Info.plist"
identity_config="$task_root/Resources/SigningIdentity.plist"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :BundleIdentifier' "$identity_config")"
expected_identity="$(/usr/libexec/PlistBuddy -c 'Print :CertificateSHA1' "$identity_config")"
source_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_root/Resources/Info.plist")"
if [[ "$bundle_identifier" != "$source_identifier" || ! "$expected_identity" =~ ^[A-F0-9]{40}$ ]]; then
    printf '프로젝트의 고정 서명 설정이 유효하지 않습니다.\n' >&2; exit 1
fi
expected_requirement="identifier \"$bundle_identifier\" and certificate leaf = H\"$expected_identity\""

# Self-signed builds use the same certificate for development and distribution.
signing_arguments=(--timestamp=none)
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    signing_identity="$CODE_SIGN_IDENTITY"
    if [[ "$signing_identity" == "-" ]]; then
        printf '임시 서명은 업데이트 시 화면 기록 승인을 잃으므로 지원하지 않습니다.\n' >&2
        exit 1
    fi
    if [[ -n "${CODE_SIGN_KEYCHAIN:-}" ]]; then
        signing_arguments+=(--keychain "$CODE_SIGN_KEYCHAIN")
    fi
else
    signing_dir="$HOME/Library/Application Support/LineLens/Signing"
    if [[ ! -f "$signing_dir/identity.sha1" || ! -f "$signing_dir/LineLens.keychain-db" ||
          ! -f "$signing_dir/password" || ! -f "$signing_dir/certificate.cer" ]]; then
        printf '고정 서명이 필요합니다. 먼저 ./scripts/setup-local-signing.sh 를 실행하세요.\n기존 앱은 보존됩니다.\n' >&2
        exit 1
    fi
    read -r signing_identity < "$signing_dir/identity.sha1"
    certificate_fingerprint="$(shasum -a 1 "$signing_dir/certificate.cer" | awk '{print toupper($1)}')"
    if [[ ! "$signing_identity" =~ ^[A-F0-9]{40}$ || "$signing_identity" != "$certificate_fingerprint" ]]; then
        printf '저장된 서명 인증서가 일치하지 않습니다. 기존 앱은 보존됩니다.\n' >&2
        exit 1
    fi
    if [[ "$signing_identity" != "$expected_identity" ]]; then
        printf '이 Mac의 인증서가 프로젝트의 배포 인증서와 다릅니다. 기존 서명 Mac에서 최종 서명하세요.\n' >&2
        exit 1
    fi
    signing_helper="$task_root/.build/tools/signing-keychain"
    mkdir -p "$task_root/.build/tools"
    if [[ ! -x "$signing_helper" || "$task_root/scripts/signing-keychain.swift" -nt "$signing_helper" ]]; then
        swiftc -suppress-warnings "$task_root/scripts/signing-keychain.swift" -o "$signing_helper"
    fi
    "$signing_helper" unlock "$signing_dir"
    signing_arguments+=(--keychain "$signing_dir/LineLens.keychain-db")
fi

# Embed the same metadata in the executable and bundle. A version-only update
# must also produce a distinct executable, so macOS does not reuse old launch
# metadata immediately after Sparkle relaunches the app.
metadata_dir="$task_root/.build/app-metadata"
mkdir -p "$metadata_dir"
info_candidate="$(mktemp "$metadata_dir/.Info.XXXXXX")"
trap 'rm -f "$info_candidate"' EXIT
cp "$task_root/Resources/Info.plist" "$info_candidate"
if [[ -n "$app_version" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$info_candidate"
fi
if [[ -n "$build_number" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$info_candidate"
fi
info_digest="$(shasum -a 256 "$info_candidate" | awk '{print $1}')"
versioned_info="$metadata_dir/$info_digest.plist"
if [[ ! -f "$versioned_info" ]]; then cp "$info_candidate" "$versioned_info"; fi
rm -f "$info_candidate"
linker_arguments=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$versioned_info")
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
app_dir="$output_dir/LineLens.app"
task_staging="$(mktemp -d "$output_dir/.build-app.XXXXXX")"
trap 'rm -rf "$task_staging"' EXIT
binary_paths=()
if [[ "$universal" == "1" ]]; then
    for task_arch in arm64 x86_64; do
        swift build -c "$configuration" --arch "$task_arch" "${linker_arguments[@]}"
        binary_dir="$(swift build -c "$configuration" --arch "$task_arch" --show-bin-path)"
        # Some SwiftPM build systems share the output path between architectures.
        # Preserve each executable before the next build can replace it.
        lipo "$binary_dir/LineLens" -verify_arch "$task_arch"
        cp "$binary_dir/LineLens" "$task_staging/LineLens-$task_arch"
        binary_paths+=("$task_staging/LineLens-$task_arch")
    done
else
    swift build -c "$configuration" "${linker_arguments[@]}"
    binary_dir="$(swift build -c "$configuration" --show-bin-path)"
    binary_paths+=("$binary_dir/LineLens")
fi
staged_app="$task_staging/LineLens.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
if [[ "$universal" == "1" ]]; then
    lipo -create "${binary_paths[@]}" -output "$staged_app/Contents/MacOS/LineLens"
else
    cp "${binary_paths[0]}" "$staged_app/Contents/MacOS/LineLens"
fi
cp "$versioned_info" "$staged_app/Contents/Info.plist"
cp "$task_root/Resources/AppIcon.icns" "$staged_app/Contents/Resources/AppIcon.icns"
# Preserve the versioned framework's symlinks. LineLens is not sandboxed, so its
# unused XPC services are omitted, as supported by Sparkle's integration guide.
framework_source="$task_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
framework="$staged_app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$staged_app/Contents/Frameworks"
ditto "$framework_source" "$framework"
rm -rf "$framework/Versions/B/XPCServices" "$framework/XPCServices"
# This project's self-signed certificate has no Apple Team ID. Use the same
# non-hardened signing mode as the host instead of enabling Library Validation.
for nested_code in "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework"; do
    codesign --force --options=0 --sign "$signing_identity" "${signing_arguments[@]}" "$nested_code"
done
codesign --force --sign "$signing_identity" "${signing_arguments[@]}" --identifier "$bundle_identifier" "$staged_app"
if ! codesign --verify --all-architectures --deep --strict -R="$expected_requirement" "$staged_app"; then
    printf '프로젝트에 고정된 배포 서명과 일치하지 않습니다. 기존 앱은 보존됩니다.\n' >&2
    exit 1
fi
new_requirement="$(codesign -d -r- "$staged_app" 2>&1 | sed -n 's/^designated => //p')"
if [[ -z "$new_requirement" || "$new_requirement" == *cdhash* ]]; then
    printf '업데이트 간 유지되는 서명이 아닙니다. 기존 앱은 보존됩니다.\n' >&2
    exit 1
fi
if [[ -d "$app_dir" ]]; then
    existing_requirement="$(codesign -d -r- "$app_dir" 2>&1 | sed -n 's/^designated => //p')"
    if [[ -n "$existing_requirement" && "$existing_requirement" != *cdhash* ]] &&
       ! codesign --verify --all-architectures --strict -R="$existing_requirement" "$staged_app"; then
        if [[ "${ALLOW_SIGNING_IDENTITY_CHANGE:-0}" != "1" ]]; then
            printf '기존 앱과 서명 신원이 다릅니다. 기존 앱은 보존됩니다.\n인증서 변경이 의도적이면 ALLOW_SIGNING_IDENTITY_CHANGE=1 을 명시하세요.\n' >&2
            exit 1
        fi
        printf '서명 인증서 변경: 화면 기록 재승인이 필요할 수 있습니다.\n' >&2
    fi
fi

same_app_payload() {
    [[ -d "$app_dir" ]] || return 1
    cmp -s "$staged_app/Contents/Info.plist" "$app_dir/Contents/Info.plist" || return 1
    codesign --verify --all-architectures --deep --strict -R="$new_requirement" "$app_dir" || return 1
    # Each nested signature has its own signing time. Compare all resources and
    # executable payloads after validating signatures; strip temporary copies only.
    ditto "$app_dir" "$task_staging/existing-payload.app" || return 1
    ditto "$staged_app" "$task_staging/staged-payload.app" || return 1
    local comparison_app nested_path
    for comparison_app in "$task_staging/existing-payload.app" "$task_staging/staged-payload.app"; do
        while IFS= read -r -d '' nested_path; do
            if file -b "$nested_path" | /usr/bin/grep -q 'Mach-O'; then
                codesign --remove-signature "$nested_path" || return 1
            fi
        done < <(find "$comparison_app" -type f -print0)
        while IFS= read -r -d '' nested_path; do rm -rf "$nested_path" || return 1; done \
            < <(find "$comparison_app" -type d -name _CodeSignature -print0)
    done
    # Compare symlinks themselves; recursive BSD diff follows framework aliases
    # and can incorrectly report directory loops for identical bundles.
    /usr/bin/rsync --dry-run --recursive --checksum --links --perms --delete --itemize-changes \
        "$task_staging/existing-payload.app/" "$task_staging/staged-payload.app/" \
        > "$task_staging/payload-diff" || return 1
    # Signing changes mtimes even when stripped payloads are identical. rsync
    # still itemizes these as timestamp-only changes under --checksum.
    /usr/bin/awk '$1 !~ /^\.[fd]\.\.[tT]\.+$/ { different = 1 } END { exit different }' \
        "$task_staging/payload-diff"
}

# Never modify an existing signed executable in place. TCC and running processes
# can otherwise retain different identities for the same app path.
if same_app_payload; then
    printf '\nApp unchanged; existing signed bundle preserved.\n'
else
    while read -r task_pid task_executable; do
        if [[ "$task_executable" == "$app_dir/Contents/MacOS/LineLens" ]]; then
            kill -TERM "$task_pid"
            for ((task_attempt = 0; task_attempt < 50; task_attempt++)); do
                if ! kill -0 "$task_pid" 2>/dev/null; then break; fi
                sleep 0.1
            done
            if kill -0 "$task_pid" 2>/dev/null; then
                printf 'LineLens did not quit; existing app was preserved.\n' >&2
                exit 1
            fi
        fi
    done < <(ps -axo pid=,comm=)
    if [[ -d "$app_dir" ]]; then mv "$app_dir" "$task_staging/previous.app"; fi
    if ! mv "$staged_app" "$app_dir"; then
        if [[ -d "$task_staging/previous.app" ]]; then mv "$task_staging/previous.app" "$app_dir"; fi
        exit 1
    fi
fi
printf '\n고정 서명: %s\n' "$signing_identity"
printf '\nBuilt: %s\nRun: open "%s"\n' "$app_dir" "$app_dir"

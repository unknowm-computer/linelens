#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
output_dir="$task_root/dist/releases"
previous_app=""
download_url_prefix=""
release_notes=""
usage() {
    printf 'Usage: %s [X.Y.Z BUILD_NUMBER] [--previous-app PREVIOUS.app] [--output-dir DIRECTORY] [--download-url-prefix HTTPS_URL/] [--release-notes NOTES.txt]\n' "$0"
}
if [[ $# -gt 0 && "$1" != -* ]]; then
    if [[ $# -lt 2 ]]; then usage >&2; exit 1; fi
    app_version="$1"
    build_number="$2"
    shift 2
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        --previous-app|--output-dir|--download-url-prefix|--release-notes)
            if [[ $# -lt 2 || -z "$2" ]]; then usage >&2; exit 1; fi
            case "$1" in
                --previous-app) previous_app="$2" ;;
                --output-dir) output_dir="$2" ;;
                --download-url-prefix) download_url_prefix="$2" ;;
                --release-notes) release_notes="$2" ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[1-9][0-9]{0,8}$ ]]; then
    printf '버전은 X.Y.Z, 빌드 번호는 1~999999999 사이의 정수여야 합니다.\n' >&2; exit 1
fi
if [[ -n "$release_notes" && ! -f "$release_notes" ]]; then
    printf '릴리스 노트 파일을 찾을 수 없습니다.\n' >&2; exit 1
fi
if [[ -z "$download_url_prefix" ]]; then
    prefix_template="$(/usr/libexec/PlistBuddy -c 'Print :DownloadURLPrefixTemplate' "$task_root/Resources/UpdateDistribution.plist")"
    download_url_prefix="${prefix_template//\{version\}/$app_version}"
fi
if [[ "$download_url_prefix" != https://*/ || "$download_url_prefix" == *\{* ]]; then
    printf '다운로드 주소 접두사는 /로 끝나는 HTTPS 주소여야 합니다.\n' >&2; exit 1
fi
if [[ -n "$previous_app" && ! -f "$previous_app/Contents/Info.plist" ]]; then
    printf '이전 배포 앱을 찾을 수 없습니다: %s\n' "$previous_app" >&2; exit 1
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
release_dir="$output_dir/$app_version"
if [[ -e "$release_dir" ]]; then
    printf '이미 만들어진 버전은 덮어쓰지 않습니다: %s\n새 버전·빌드 번호를 사용하세요.\n' "$release_dir" >&2
    exit 1
fi
source "$task_root/scripts/sparkle-tools.sh"
tools_dir="$(sparkle_tools_dir)"
verify_sparkle_key "$tools_dir" "$task_root/Resources/Info.plist"
task_staging="$(mktemp -d "$output_dir/.package-release.XXXXXX")"
trap 'rm -rf "$task_staging"' EXIT
payload="$task_staging/payload"
artifacts="$task_staging/artifacts"
mkdir -p "$artifacts"
"$task_root/scripts/build-app.sh" release --universal --version "$app_version" \
    --build-number "$build_number" --output-dir "$payload"
app_dir="$payload/LineLens.app"
if [[ -n "$previous_app" ]]; then
    "$task_root/scripts/verify-update.sh" "$previous_app" "$app_dir"
fi
lipo "$app_dir/Contents/MacOS/LineLens" -verify_arch arm64 x86_64
cp "$task_root/docs/distribution-install.txt" "$payload/INSTALL.txt"
archive_name="LineLens-$app_version-universal.zip"
ditto -c -k --sequesterRsrc "$payload" "$artifacts/$archive_name"

# Validate the delivered archive, not just the bundle before compression.
extracted_dir="$task_staging/extracted"
ditto -x -k "$artifacts/$archive_name" "$extracted_dir"
identity_config="$task_root/Resources/SigningIdentity.plist"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :BundleIdentifier' "$identity_config")"
fingerprint="$(/usr/libexec/PlistBuddy -c 'Print :CertificateSHA1' "$identity_config")"
requirement="identifier \"$bundle_identifier\" and certificate leaf = H\"$fingerprint\""
codesign --verify --all-architectures --deep --strict -R="$requirement" "$extracted_dir/LineLens.app"
lipo "$extracted_dir/LineLens.app/Contents/MacOS/LineLens" -verify_arch arm64 x86_64
cmp "$app_dir/Contents/MacOS/LineLens" "$extracted_dir/LineLens.app/Contents/MacOS/LineLens"
cmp "$app_dir/Contents/Info.plist" "$extracted_dir/LineLens.app/Contents/Info.plist"
cmp "$task_root/docs/distribution-install.txt" "$extracted_dir/INSTALL.txt"
if [[ -n "$previous_app" ]]; then
    "$task_root/scripts/verify-update.sh" "$previous_app" "$extracted_dir/LineLens.app"
fi
if [[ -n "$release_notes" ]]; then
    cp "$release_notes" "$artifacts/${archive_name%.zip}.txt"
fi
"$tools_dir/generate_appcast" --account com.linelens.app --maximum-deltas 0 \
    --download-url-prefix "$download_url_prefix" --embed-release-notes \
    -o "$artifacts/appcast.xml" "$artifacts"
"$tools_dir/sign_update" --account com.linelens.app --verify "$artifacts/appcast.xml"
swift "$task_root/scripts/verify-sparkle.swift" "$extracted_dir/LineLens.app/Contents/Info.plist" \
    "$artifacts/appcast.xml" "$artifacts/$archive_name" "$download_url_prefix"
(
    cd "$artifacts"
    shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
{
    printf 'LineLens %s (build %s)\n' "$app_version" "$build_number"
    printf 'Minimum macOS: 15.0\nArchitectures: arm64 x86_64\n'
    printf 'Bundle ID: %s\nCertificate SHA-1: %s\n' "$bundle_identifier" "$fingerprint"
    printf 'Signing: self-signed, no Apple notarization\n'
    printf 'Update feed: %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app_dir/Contents/Info.plist")"
    printf 'Sparkle: signed appcast.xml and EdDSA-signed ZIP\n'
    codesign -d -r- "$extracted_dir/LineLens.app" 2>&1 | sed -n '/^designated => /p'
} > "$artifacts/release-info.txt"
mv "$artifacts" "$release_dir"
printf '\n배포 파일: %s/%s\n체크섬: %s/%s.sha256\n' "$release_dir" "$archive_name" "$release_dir" "$archive_name"
printf 'Sparkle 피드: %s/appcast.xml\n게시할 때 ZIP과 appcast.xml을 같은 GitHub Release에 첨부하세요.\n' "$release_dir"

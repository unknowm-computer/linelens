#!/bin/bash
set -euo pipefail
umask 077

task_root="$(cd "$(dirname "$0")/.." && pwd)"
signing_dir="$HOME/Library/Application Support/LineLens/Signing"
helper="$task_root/.build/tools/signing-keychain"
identity_config="$task_root/Resources/SigningIdentity.plist"
expected_identity=""
if [[ -f "$identity_config" ]]; then
    expected_identity="$(/usr/libexec/PlistBuddy -c 'Print :CertificateSHA1' "$identity_config")"
    if [[ ! "$expected_identity" =~ ^[A-F0-9]{40}$ ]]; then
        printf '프로젝트에 고정된 인증서 지문이 유효하지 않습니다.\n' >&2; exit 1
    fi
    if [[ ! -d "$signing_dir" ]]; then
        printf '이 프로젝트는 기존 배포 인증서에 고정되어 있습니다.\n이 Mac에서 새 인증서를 생성하지 않습니다. 원래 서명 Mac에서 최종 앱을 서명하세요.\n설치받는 Mac에서는 이 스크립트를 실행할 필요가 없습니다.\n' >&2
        exit 1
    fi
fi
mkdir -p "$task_root/.build/tools"
swiftc -suppress-warnings "$task_root/scripts/signing-keychain.swift" -o "$helper"

if [[ -d "$signing_dir" ]]; then
    if [[ ! -f "$signing_dir/identity.sha1" || ! -f "$signing_dir/LineLens.keychain-db" ||
          ! -f "$signing_dir/password" || ! -f "$signing_dir/certificate.cer" ]]; then
        printf '서명 폴더가 불완전합니다. 기존 키를 자동으로 덮어쓰지 않습니다: %s\n' "$signing_dir" >&2
        exit 1
    fi
    read -r fingerprint < "$signing_dir/identity.sha1"
    actual_fingerprint="$(shasum -a 1 "$signing_dir/certificate.cer" | awk '{print toupper($1)}')"
    if [[ ! "$fingerprint" =~ ^[A-F0-9]{40}$ || "$fingerprint" != "$actual_fingerprint" ]]; then
        printf '저장된 인증서가 일치하지 않습니다. 기존 서명을 자동 교체하지 않습니다.\n' >&2
        exit 1
    fi
    if [[ -n "$expected_identity" && "$fingerprint" != "$expected_identity" ]]; then
        printf '이 Mac의 인증서가 프로젝트의 배포 인증서와 다릅니다. 기존 서명을 교체하지 않습니다.\n' >&2
        exit 1
    fi
    "$helper" unlock "$signing_dir"
    printf '기존 LineLens 서명 키를 유지합니다: %s\n' "$signing_dir"
    exit 0
fi

mkdir -p "$signing_dir"
chmod 700 "$signing_dir"
task_staging="$(mktemp -d "$signing_dir/.setup.XXXXXX")"
trap 'rm -rf "$task_staging"; rm -f "$signing_dir/identity.p12"' EXIT
openssl rand -hex 32 | tr -d '\n' > "$signing_dir/password"
cat > "$task_staging/certificate.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = LineLens Local Development
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
openssl req -new -x509 -newkey rsa:3072 -sha256 -days 3650 \
    -config "$task_staging/certificate.cnf" \
    -keyout "$task_staging/private.pem" -out "$task_staging/certificate.pem" \
    -passout "file:$signing_dir/password" 2> "$task_staging/openssl.log"
openssl x509 -in "$task_staging/certificate.pem" -outform DER -out "$signing_dir/certificate.cer"
# OpenSSL reads two lines when passin/passout refer to the same file.
cp "$signing_dir/password" "$task_staging/export-password"
openssl pkcs12 -export -name 'LineLens Local Development' \
    -inkey "$task_staging/private.pem" -in "$task_staging/certificate.pem" \
    -passin "file:$signing_dir/password" -passout "file:$task_staging/export-password" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$signing_dir/identity.p12"
"$helper" create "$signing_dir"

# Only the current user's code-signing policy. No TLS trust or system roots.
printf 'LineLens 인증서의 코드 서명 신뢰를 현재 사용자에 등록합니다.\n'
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$signing_dir/LineLens.keychain-db" "$signing_dir/certificate.cer"
fingerprint="$(shasum -a 1 "$signing_dir/certificate.cer" | awk '{print toupper($1)}')"

# Confirm the key is usable before publishing the configuration.
printf 'int main(void) { return 0; }\n' > "$task_staging/probe.c"
clang "$task_staging/probe.c" -o "$task_staging/probe"
codesign --force --sign "$fingerprint" --keychain "$signing_dir/LineLens.keychain-db" \
    --identifier com.linelens.signing-probe "$task_staging/probe"
codesign --verify --strict "$task_staging/probe"
printf '%s\n' "$fingerprint" > "$signing_dir/identity.sha1"
printf '\n고정 서명 설정 완료: %s\n인증서 SHA-1: %s\n' "$signing_dir" "$fingerprint"

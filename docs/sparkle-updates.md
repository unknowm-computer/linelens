# 배포·Sparkle 업데이트

기준일: 2026-11-04. 현재 코드·서명·패키징 절차를 정리한다. 공개 서버 게시 상태는 릴리스마다 별도로 확인한다.

LineLens 0.1.2 (build 3)부터 Sparkle 2.10.1을 포함한다. 메뉴 막대와 설정의 ‘업데이트 확인…’에서 업데이트를 확인하고 내려받아 설치·재실행한다. ‘자동으로 업데이트 확인’은 설정에서 켤 수 있으며 기본값은 끄기다. 자동 설치는 끄고 새 버전을 설치할 때 사용자가 선택하도록 했다. OCR·번역 내용은 업데이트 서버에 보내지 않는다.

## 공개 주소

- `Resources/Info.plist`의 `SUFeedURL`: `https://github.com/unknowm-computer/linelens/releases/latest/download/appcast.xml`
- `Resources/UpdateDistribution.plist`의 `DownloadURLPrefixTemplate`: `https://github.com/unknowm-computer/linelens/releases/download/v{version}/`
- GitHub Release 태그는 `v0.1.2`와 같이 버전 앞에 `v`를 붙인다.

이 주소들은 소스에 설정된 게시 위치다. 앱이나 패키징 스크립트가 GitHub Release를 생성·공개하지는 않는다. 저장소·릴리스가 비공개이거나 파일이 아직 게시되지 않으면 일반 사용자에게 업데이트를 제공할 수 없으므로, 배포할 때 비로그인 환경에서 피드와 ZIP 주소를 확인한다. 필요하면 공개 배포용 저장소·별도 HTTPS 서버로 설정을 변경한다. 비공개 저장소 토큰을 앱에 포함하지 않는다.

별도 서버를 사용하면 `SUFeedURL`을 고정된 `https://배포호스트/appcast.xml`로 바꾸고 다운로드 접두사도 수정한다. 일회성 패키징에는 `--download-url-prefix https://배포호스트/0.1.2/`를 사용할 수 있다. 접두사는 `/`로 끝나야 한다. 앱에 포함된 피드 주소를 바꾸려면 새 버전 배포가 필요하므로 기존 주소는 업데이트가 이어지도록 유지한다.

## 두 종류의 서명

| 용도 | 보관·설정 | 유지할 값 |
| --- | --- | --- |
| 앱 코드 서명·화면 기록 권한 신원 | 기존 LineLens 전용 서명 키체인, `Resources/SigningIdentity.plist` | Bundle ID와 같은 인증서·개인 키 |
| 업데이트 ZIP·appcast 검증 | 로그인 키체인의 Sparkle 항목, account `com.linelens.app` | 같은 Ed25519 개인 키, `Info.plist`의 `SUPublicEDKey` |

두 키는 서로 대체하지 않는다. Sparkle를 추가해도 기존 앱 코드 서명은 바뀌지 않는다. 업데이트용 공개 키는 앱과 Git에 포함해도 되며, 개인 키는 배포 ZIP이나 저장소에 넣지 않는다.

```sh
./scripts/setup-sparkle.sh
```

최초 설정 때 공식 `generate_keys`로 키를 생성해 로그인 키체인에 저장하고 공개 키를 `Info.plist`에 고정한다. 이후에는 기존 키 일치 여부만 확인한다. 고정된 공개 키가 있는데 개인 키가 없거나 다르면 중단한다. 새 키를 자동 생성해 기존 업데이트 경로를 끊지 않는다.

서명된 피드(`SURequireSignedFeed`)와 압축 해제 전 ZIP 검증(`SUVerifyUpdateBeforeExtraction`)을 사용한다. 생성 후 `appcast.xml`을 손으로 편집하면 서명이 무효가 되므로 다시 서명·검증해야 한다.

## 릴리스 만들기

`package-release.sh`는 고정 코드 서명과 Sparkle 업데이트 서명 키가 있는 배포 Mac에서 실행한다. 다른 Mac에서는 `./scripts/build-app.sh debug` 또는 `release --signing development`로 개인 키 없이 개발할 수 있다. 개발 앱은 별도 Bundle ID를 사용하고 Sparkle를 시작하지 않는다.

아래 버전·빌드 번호는 명령 형식의 예시다. 실제 배포는 이전보다 높은 빌드 번호와 아직 생성하지 않은 버전을 사용한다. `dist/releases/<version>`이 이미 있으면 덮어쓰지 않고 중단한다.

```sh
./scripts/package-release.sh 0.1.2 3 \
  --previous-app /path/to/previous/LineLens.app \
  --release-notes /path/to/release-notes.txt
```

`--previous-app`과 `--release-notes`는 선택 사항이다. 표시 버전과 `CFBundleVersion`을 함께 올린다. Sparkle는 빌드 번호로 새 버전을 비교하며, 이전 앱을 지정하면 증가 여부와 코드 서명 호환성을 검증한다.

빌드 스크립트는 최종 `Info.plist`를 앱 번들과 실행 파일에 동일하게 포함한다. 소스 코드를 바꾸지 않고 버전만 올려도 실행 파일에 반영되므로, 업데이트 재실행 직후 이전 실행 메타데이터가 재사용되는 문제를 방지한다. 동일한 버전을 반복 빌드하면 기존 번들을 보존한다.

패키징은 `release` + `distribution` 빌드를 사용한다. 실행 파일의 디버그·로컬 심벌과 Sparkle의 개발용 헤더·모듈은 최종 코드 서명 전에 정리한다. Sparkle 런타임·설치 도우미, 기존 코드 서명 신원, 업데이트 공개 키와 서명 검증 설정은 유지한다. 개발 빌드와 원본 SDK에는 이 정리를 적용하지 않는다.

`dist/releases/0.1.2/`에 다음 파일을 만든다.

- `LineLens-0.1.2-universal.zip`: Sparkle.framework와 필요한 설치 도우미를 포함한 서명 앱, 설치 안내
- `LineLens-0.1.2-universal.zip.sha256`: 다운로드 확인용 체크섬
- `appcast.xml`: ZIP의 버전·크기·다운로드 주소·EdDSA 서명, 피드 자체 서명
- `release-info.txt`: 코드 서명·배포 정보
- 선택한 릴리스 노트 파일

공식 `generate_appcast`로 전체 ZIP 업데이트용 피드를 만든다. 델타 업데이트는 생성하지 않는다. 매 릴리스 피드는 현재 버전 한 항목을 포함하며, 지원 OS·아키텍처가 같은 현재 배포 방식에 맞춘다. 과거 OS용 분기 피드가 필요해지면 이 방식을 확장한다. ZIP을 다시 압축 해제해 코드 서명을 검사하고, 앱에 고정된 공개 키로 ZIP 서명을 검증한다. 공식 `sign_update --verify`로 피드 서명도 확인한다.

2026-11-04에는 정리된 통합 앱의 두 아키텍처 코드 서명과 기존 `0.1.4 (5)`의 서명 요구조건 충족, ZIP·피드 EdDSA 서명을 확인했다. 격리된 이전 앱과 로컬 피드로 검증용 `0.1.5 (6)`을 실제 다운로드·설치·재실행했고 화면 기록·접근성 허용 상태가 유지됐다. 변조된 ZIP·피드·실행 파일은 검증에서 거부됐다. 이 검증은 공개 서버를 거치지 않은 로컬 테스트이며 실제 게시물의 버전·다운로드 확인은 릴리스마다 별도로 수행한다. 상세 범위는 [테스트 문서](manual-testing.md)를 따른다.

## GitHub Releases에 게시

1. 공개 배포 저장소에 태그 `v0.1.2`의 정식 Release를 만든다.
2. 위 ZIP과 `appcast.xml`을 **동일한 Release**에 첨부한다. 체크섬·릴리스 정보도 함께 제공할 수 있다.
3. 해당 Release를 최신 정식 릴리스로 지정한다. 초안·프리릴리스는 `releases/latest`의 배포 대상으로 사용하지 않는다.
4. 비로그인 환경에서 `SUFeedURL`과 appcast의 ZIP 주소가 실제 파일을 반환하는지 확인한다.
5. 이전 Sparkle 포함 버전에서 ‘업데이트 확인…’을 실행해 설치·재실행과 화면 기록 접근을 확인한다.

ZIP만 올리면 업데이트를 찾을 수 없다. `appcast.xml`만 올리고 ZIP 주소가 틀려도 설치할 수 없다. 로컬 파일을 만들었다는 사실만으로 서버 배포가 완료되는 것은 아니다.

0.1.1 이하에는 Sparkle가 없으므로 0.1.2 이상으로 한 번 수동 교체해야 한다. 자체 서명은 Apple 공증과 다르며, Sparkle를 사용해도 macOS의 실행 허용 안내가 별도로 나타날 수 있다.

## 다른 Mac에서 기존 서명으로 배포하기

배포용 Mac에는 Xcode와 LineLens 저장소, 기존 코드 서명 키체인, 기존 Sparkle 키가 필요하다. 이전용 `LineLens-Release-Signing.7z`에는 전용 `Signing` 폴더와 `LineLens-Sparkle.key`가 들어 있다. 암호화 파일은 안전한 경로로 전달하고 암호는 별도로 보관한다.

1. 이전용 파일을 7z를 지원하는 도구로 열고, 압축을 푼 위치를 아래 `transfer_dir`에 지정한다. 새 Mac의 LineLens 저장소에서 실행한다. 기존 `Signing` 폴더가 있다면 `./scripts/setup-local-signing.sh`로 지문을 확인하고 복사 단계는 건너뛴다.

   ```sh
   (
     set -e
     umask 077
     transfer_dir="/path/to/extracted-release-signing"
     signing_dir="$HOME/Library/Application Support/LineLens/Signing"
     for name in LineLens.keychain-db password certificate.cer identity.sha1; do
       test -f "$transfer_dir/Signing/$name"
     done
     mkdir -p "$(dirname "$signing_dir")"
     mkdir -m 700 "$signing_dir"
     for name in LineLens.keychain-db password certificate.cer identity.sha1; do
       install -m 600 "$transfer_dir/Signing/$name" "$signing_dir/$name"
     done
   )
   ```

2. 키체인을 열고 인증서 지문이 프로젝트와 일치하는지 확인한 뒤, 현재 사용자의 코드 서명 정책에 인증서를 등록한다. macOS가 인증을 요청하면 새 Mac에서 승인한다.

   ```sh
   signing_dir="$HOME/Library/Application Support/LineLens/Signing"
   ./scripts/setup-local-signing.sh &&
     security add-trusted-cert -r trustRoot -p codeSign \
       -k "$signing_dir/LineLens.keychain-db" "$signing_dir/certificate.cer"
   ```

3. Sparkle 키를 로그인 키체인에 가져오고 앱의 공개 키와 일치하는지 확인한다. 이미 가져온 경우 `setup-sparkle.sh`로 확인한다.

   ```sh
   swift package resolve &&
     .build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.linelens.app \
       -f /path/to/extracted-release-signing/LineLens-Sparkle.key &&
     ./scripts/setup-sparkle.sh
   ```

4. 새 버전과 증가한 빌드 번호로 `package-release.sh`를 실행한다. `--previous-app`에 기존 배포 앱을 지정하면 새 앱이 기존 코드 서명 요구조건을 만족하는지 확인한다. 검증된 ZIP과 `appcast.xml`은 위의 [GitHub Releases 게시 절차](#github-releases에-게시)를 따른다.

### Sparkle 키만 내보내거나 가져오기

Sparkle의 `generate_keys`는 `-x`로 기존 개인 키를 파일에 내보내고 `-f`로 로그인 키체인에 가져온다. 개인 키 파일은 안전한 경로에 보관한다.

```sh
# 기존 Mac: 개인 키를 안전한 저장 위치로 내보내기
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.linelens.app \
  -x /secure/path/linelens-sparkle-private-key
# 새 Mac: swift package resolve 후 가져오기
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.linelens.app \
  -f /secure/path/linelens-sparkle-private-key
./scripts/setup-sparkle.sh
```

코드 서명 개인 키의 이전에는 위의 전용 `Signing` 폴더를 사용한다. 최종 앱은 기존 코드 서명 신원을 유지해야 화면 기록 승인 연결을 보존할 수 있다. 자체 서명 배포에서 Sparkle 개인 키를 잃으면 기존 사용자의 수동 재설치가 필요할 수 있다.

## 참고

- [Sparkle 기본 설정·서명](https://sparkle-project.org/documentation/)
- [SwiftUI에서 Sparkle 시작](https://sparkle-project.org/documentation/programmatic-setup/)
- [설정과 서명된 피드](https://sparkle-project.org/documentation/customization/)

# 설치·자동 실행·권한·빌드 서명

기준일: 2026-11-04. 사용자의 설치·권한 안내와 개발 Mac의 서명 운영 절차를 정리한다.

## 설치받는 사용자

배포 ZIP을 풀어 `LineLens.app`을 `/Applications`처럼 유지할 위치에 설치한다. 개발 도구·서명 키체인은 설치받는 Mac에 필요하지 않다. 상세 설치 순서는 [배포 설치 안내](distribution-install.txt)를 따른다.

현재 앱은 고정 자체 서명을 사용하며 Developer ID 공증은 포함하지 않는다. macOS의 앱 실행 허용과 화면 기록 승인은 별개다. 일반 업데이트에서는 화면 기록 항목을 삭제하거나 권한을 초기화하지 않는다.

## 로그인 시 자동 실행

설정 → 일반 → ‘로그인 시 자동 실행’에서 켜고 끈다. `SMAppService.mainApp`으로 등록하며 별도의 관리자 도우미·LaunchDaemon을 설치하지 않는다. 새 설치에서 강제로 켜거나 실행할 때마다 재등록하지 않는다.

- 상태는 별도 저장 값이 아니라 실제 시스템 등록 상태를 읽는다. 시스템 설정에서 변경하고 앱으로 돌아오면 반영한다.
- 승인 대기 중에는 체크와 안내를 유지하고 ‘로그인 항목 설정 열기’로 이동할 수 있다.
- 등록 실패는 오류와 실제 시스템 상태를 표시한다. 해제는 다음 로그인부터 자동 실행을 중단하며 현재 앱을 종료하지 않는다.
- 다른 위치의 복사본으로 전환하거나 앱을 이동하면 해당 복사본의 등록 상태를 확인한다.

실제 등록·해제·재빌드 후 등록 유지와 실제 로그인 후 실행은 별도 검증 항목이다.

## 권한 확인

설정 → 권한에서 확인·요청·시스템 설정 열기를 제공한다. 시스템 오디오는 녹음하지 않는다. 자동 실행 등록은 아래 권한을 새로 부여하거나 초기화하지 않는다.

| 권한 | 용도 | 미허용 시 |
| --- | --- | --- |
| 화면 기록 | 화면·창 캡처와 OCR | 시스템 설정에서 승인 필요 |
| 접근성 | 앱이 제공하는 텍스트 직접 읽기 | 화면 OCR·번역으로 사용 가능 |

화면 기록은 실제 ScreenCaptureKit 접근으로 확인한다. CoreGraphics 사전 확인값만으로 차단하지 않고 권한 거부·기타 오류·재실행 필요를 구분한다. 접근성 상태는 `AXIsProcessTrusted()`로 읽는다.

## 화면 기록 승인이 적용되지 않을 때

기존 빌드와 새 빌드의 서명 신원이 다르면 시스템 설정에서 토글이 켜져 있어도 접근이 거부될 수 있다. 과거 실제 로그에서 `Failed to match existing code requirement`와 `SecStaticCodeCheckValidity status: -67050`을 확인했다.

1. 설정의 ‘권한 상태 다시 확인’으로 실제 접근을 확인한다.
2. macOS 승인 변경 후 적용되지 않으면 앱을 재실행한다.
3. 서명 승인 연결이 맞지 않는 경우 권한 안내·복구 화면의 ‘권한 연결 초기화’ → ‘앱 다시 실행’ → 현재 앱 허용 순서로 복구한다.

같은 복구를 실행하는 스크립트:

```sh
./scripts/reset-screen-permission.sh --relaunch
```

배포 앱의 초기화 대상은 `ScreenCapture`와 `com.linelens.app`뿐이다. 개발 앱은 아래의 별도 식별자를 사용한다. 다른 앱·접근성·마이크 권한은 변경하지 않는다. 초기화는 승인을 대신하지 않으며, 재실행 전 추가 조회를 막아 오래된 거부 상태가 다시 저장되는 것을 피한다. 정상 업데이트의 정기 절차로 사용하지 않는다.

## 다른 Mac에서 키 없이 개발하기

```sh
./scripts/build-app.sh debug
open "dist/development/LineLens Dev.app"
```

`debug`는 개발 모드가 기본이다. 최적화가 필요한 개발 테스트에는 `./scripts/build-app.sh release --signing development`를 사용한다. Xcode 선택이 필요하면 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 명령 앞에 지정한다.

개발 모드는 인증서·개인 키·배포 키체인을 열지 않고 임시 서명(`ad-hoc`)을 사용한다. 이름은 `LineLens Dev`, Bundle ID는 `com.linelens.app.dev`, 기본 출력은 `dist/development/LineLens Dev.app`이다. 설정과 시스템 권한이 배포 앱과 구분되며, 앱 내 화면 기록 복구는 실행 중인 앱의 Bundle ID만 초기화한다. 기존 `reset-screen-permission.sh`는 배포 앱용이다.

개발 앱에는 화면 기록·접근성을 별도로 승인해야 한다. 임시 서명은 코드가 바뀌면 서명 요구조건도 바뀌므로 재빌드 뒤 권한 재승인이 필요할 수 있다. 개발 앱은 Sparkle를 시작하지 않으며 배포 업데이트를 설치하지 않는다.

## 배포용 고정 코드 서명

```sh
./scripts/setup-local-signing.sh
./scripts/build-app.sh release
```

`release`는 배포 모드가 기본이며, `--signing distribution`으로 명시할 수도 있다. 배포 앱은 `dist/LineLens.app`에 생성한다. 프로젝트의 Bundle ID·공개 인증서 지문은 `Resources/SigningIdentity.plist`에 고정한다. 기존 개인 키를 보유한 서명 Mac의 설정을 재사용한다. 개인 키가 없는 다른 Mac에서 새 인증서를 만들어 대체하지 않는다.

- 전용 저장 위치는 `~/Library/Application Support/LineLens/Signing`이며 Git·배포 ZIP에 포함하지 않는다. 디렉터리 권한은 `700`, 비밀번호 등 파일은 `600`이다.
- `LineLens Local Development` 자체 서명 인증서와 RSA 3072비트 키를 사용한다. 인증서 유효기간은 10년이며 개인 키는 전용 `LineLens.keychain-db`에 내보내기 불가로 보관한다. 생성 중의 PEM·PKCS#12는 정리한다.
- 키체인 암호를 인자·로그로 출력하지 않는다. 개인 키 ACL은 codesign 용도에 제한하고, 기본 키체인·사용자 검색 목록은 변경하지 않는다. 키체인은 잠자기·15분 경과 시 잠그고 빌드 전에 전용 도구로 연다.
- 인증서 신뢰는 현재 사용자의 CodeSigning 정책에 한정한다. TLS·시스템 공통 루트를 추가하지 않는다. 설정이 불완전하거나 다른 인증서를 발견해도 자동으로 키를 재생성하지 않는다.
- `CODE_SIGN_IDENTITY`와 선택적인 `CODE_SIGN_KEYCHAIN`은 고정 인증서와 일치해야 한다. 설정 없음·불일치·서명 실패에서는 기존 앱을 보존하고 중단한다. 임시 서명으로 자동 전환하지 않는다.
- 새 앱은 기존 앱의 DR(Designated Requirement)을 만족해야 한다. 의도적인 인증서 교체는 공개 지문 설정 변경과 `ALLOW_SIGNING_IDENTITY_CHANGE=1`이 필요하며 재승인이 필요할 수 있다.

개인 키를 잃거나 인증서를 교체하면 같은 서명 신원을 유지할 수 없다. 현재 최종 서명 Mac을 변경하려면 별도 이전 계획이 필요하다. 설치받는 Mac에는 개인 키·키체인을 복사하지 않는다.

## 앱 교체와 배포 검증

빌드 스크립트는 별도 디렉터리에서 앱을 조립·서명·검증한 뒤 교체한다. 변경된 앱을 교체할 때 해당 경로의 기존 프로세스를 종료한다. 서명을 제외한 결과가 같으면 기존 번들과 실행 프로세스를 보존한다. 실행 파일의 `__TEXT,__info_plist`에도 최종 메타데이터를 반영한다.

배포 ZIP은 Apple Silicon·Intel 통합 앱과 설치 안내를 포함한다. 버전·빌드 번호, 모든 아키텍처의 서명, 이전 앱의 DR 충족과 ZIP 압축 해제 후 내용을 검사한다. 업데이트 ZIP·피드의 EdDSA 서명은 코드 서명과 다른 키다. 생성·검증·게시 명령은 [Sparkle 배포 문서](sparkle-updates.md)를 따른다.

다른 Mac에서는 이전 배포본 설치·최초 승인 → 새 버전으로 같은 경로에 교체 → 권한 초기화 없이 캡처·설정 유지 확인 순서로 검증한다. 같은 Mac에서의 서명 검사와 다른 Mac에서의 실제 승인 유지는 구분한다.

## 앱 아이콘

`Resources/AppIcon.icns`를 서명 전에 앱 번들의 `Contents/Resources`에 복사하고 `CFBundleIconFile`로 지정한다. `Resources/AppIcon.png`는 1024px 미리보기이며 메뉴 막대는 기존 시스템 심벌을 사용한다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift scripts/generate-app-icon.swift
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-app.sh release
```

아이콘은 AppKit 벡터 경로로 생성한다. 위 명령은 재생성 절차이며 일반 설치·실행에 필요하지 않다.

## 검증 범위

2026-11-04에는 테스트 96개(앱 72개·코어 24개), 개인 키를 사용하지 않는 개발용 Debug 빌드·통합 Release 빌드, 변경 없는 개발 앱의 재빌드 보존을 확인했다. 배포용 Release 빌드의 고정 서명과 임시 서명 거부도 검사했다. 검증 과정에서 기존 `dist/LineLens.app`의 실행 파일·메타데이터와 수정 시각이 보존되는 것을 확인했다. 다른 Mac에서의 실제 실행·권한 승인은 별도 확인 대상이다.

기존 Mac에서 같은 서명의 개발·릴리스 교체와 ZIP 설치 후 화면 기록 유지, 변경 없는 빌드 보존, 잘못된 서명·빌드 번호 거부를 확인했다. 로그인 항목 등록·해제·재실행 후 유지와 아이콘 표시도 확인했다. 실제 로그아웃·재부팅, 다른 Mac의 승인 유지, Intel 하드웨어 실행과 공개 서버의 업데이트는 추가 확인 대상이다. 세부 기록은 [테스트 문서](manual-testing.md)를 따른다.

## 참고

- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple TN2206: 코드 서명과 DR](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

# 화면 기록 권한과 빌드 서명

2026-11-02 실제 macOS 권한 로그에서 다음 오류를 확인했다.

```text
Failed to match existing code requirement for subject com.linelens.app and service kTCCServiceScreenCapture
Stored requirement: cdhash H"ffb715fb5ae760b9dab989ff9e580ff1ac4c43c0"
Running build:      cdhash H"7e5d575a28fc8c9b261b5b93243046782a4dc211"
SecStaticCodeCheckValidity status: -67050
```

설정의 토글은 켜져 있었지만 저장된 승인 대상과 현재 빌드의 서명이 달라 ScreenCaptureKit 접근이 거부되었다. 이전에 제안한 항목 삭제·재등록만으로는 이 기록이 갱신되지 않았다.

## 수정

- 빌드 결과를 기존 `.app` 내부에 덮어쓰지 않고, 별도 디렉터리에서 조립·서명·검증한 다음 교체한다.
- 변경된 앱을 교체하기 전에 해당 경로에서 실행 중인 앱을 종료한다.
- 동일한 결과물이면 기존 앱을 보존하여 불필요한 교체를 피한다.
- 앱과 복구 스크립트에서 `tccutil reset ScreenCapture com.linelens.app`만 수행한다.
- 초기화 후 앱 재실행 전에는 추가 권한 조회를 차단한다. 새 프로세스에서 현재 빌드를 승인해야 한다.
- 화면 접근 실패 시 오류 domain/code와 사전 확인 결과를 기록한다. 캡처 이미지나 OCR 텍스트는 진단 로그에 남기지 않는다.

임시 서명은 코드가 바뀌면 서명 해시도 바뀐다. 패키징 수정만으로 서로 다른 빌드 간 승인이 유지되지는 않아, 이후 개발과 배포에 동일한 자체 서명 인증서를 적용했다.

## 고정 서명 설정

```sh
./scripts/setup-local-signing.sh # 서명 Mac의 기존 키 확인·키체인 열기
./scripts/build-app.sh
```

- `LineLens Local Development`라는 자체 서명 코드 서명 인증서와 RSA 3072비트 키를 생성한다. 인증서 유효기간은 10년이다.
- 저장 위치는 `~/Library/Application Support/LineLens/Signing`이며 저장소에 포함하지 않는다. 폴더는 `700`, 비밀번호 등 파일은 `600` 권한이다.
- 개인 키는 전용 `LineLens.keychain-db`에 서명 용도·내보내기 불가로 가져온다. 생성 중의 PEM·PKCS#12는 정리한다. 키체인을 열기 위한 임의 비밀번호는 같은 전용 폴더의 `password`에 보관하며, 명령줄 인자나 로그로 출력하지 않는다.
- 개인 키 ACL에는 `/usr/bin/codesign`을 지정한다. 키체인은 잠자기 및 15분 경과 시 잠기며 빌드 직전에 전용 도구로 연다. 기본 키체인과 사용자 키체인 검색 목록을 변경하지 않는다.
- 인증서 신뢰는 현재 사용자의 `CodeSigning` 정책에만 등록한다. TLS 신뢰나 시스템 공통 루트는 추가하지 않는다. 이 단계에는 macOS 시스템 인증이 필요하다.
- 재실행 시 기존 인증서를 재사용한다. 불완전한 설정이나 다른 인증서를 발견해도 키를 자동으로 새로 만들지 않는다. 이 폴더를 삭제·재생성하면 기존 앱의 신원을 잃으므로 보존해야 한다.
- `Resources/SigningIdentity.plist`에는 배포 인증서의 공개 SHA-1 지문과 Bundle ID만 저장한다. 모든 빌드·배포본은 이 인증서에 일치해야 한다. 개인 키가 없는 다른 Mac에서 설정 스크립트를 실행해 새 인증서를 만드는 것도 차단한다.
- 빌드는 설정이 없거나 서명·검증에 실패하면 기존 앱을 보존하고 중단한다. 임시 서명으로 자동 전환하지 않는다.
- 새 빌드는 기존 앱의 DR(Designated Requirement)을 만족해야 한다. 의도적으로 인증서를 교체하려면 프로젝트의 공개 지문도 변경하고 `ALLOW_SIGNING_IDENTITY_CHANGE=1`을 지정해야 한다. 이 경우 재승인이 필요할 수 있다.
- 인증서 서명에는 서명 시각이 포함되므로, 서명 검증 후 임시 복사본에서 서명만 제거해 실행 파일 내용을 비교한다. 같은 결과물이면 기존 앱과 실행 중 프로세스를 유지한다.

인증서 이름에 `Local Development`가 있지만 서명된 앱의 실행을 이 Mac에 묶는 것은 아니다. 개인 키를 보유한 이 Mac에서 모든 배포 버전을 같은 인증서로 서명한다. 설치받는 Mac에는 개인 키·키체인을 복사하지 않는다. 자체 서명은 Developer ID 서명·공증을 대신하지 않으므로 설치·업데이트 시 macOS의 앱 실행 허용이 필요할 수 있다.

## 배포 파일 생성과 업데이트 검사

```sh
./scripts/package-release.sh 0.1.0 1
./scripts/package-release.sh 0.1.1 2 --previous-app /path/to/previous/LineLens.app
```

- Apple Silicon·Intel용 실행 파일을 각각 컴파일해 통합 앱을 만든다.
- 버전과 빌드 번호를 서명 전에 반영하고, 원본 `Resources/Info.plist`와 실행 중인 개발 앱은 변경하지 않는다.
- 프로젝트에 고정된 인증서를 모든 아키텍처가 만족하는지 검증한다.
- `dist/releases/<version>`에 ZIP·SHA-256 체크섬·공개 서명 정보를 생성한다. 이미 생성된 버전은 덮어쓰지 않는다.
- ZIP에는 `LineLens.app`과 한국어 설치 안내 `INSTALL.txt`만 넣는다. 압축 해제 후 서명·실행 파일·Info.plist·설치 안내를 재검증한다.
- 이전 앱을 지정하면 압축 전과 압축 해제 후 모두 `verify-update.sh`로 검사한다. Bundle ID·고정 인증서·기존 앱의 DR 일치와 빌드 번호 증가가 필수다. 권한 초기화는 수행하지 않는다.

서명 키는 내보내기 불가이므로, 새 Mac에서 새 인증서를 생성하는 방식으로 서명 Mac을 변경하지 않는다. 현재 배포 절차는 이 Mac을 최종 서명용으로 사용한다. 키를 잃거나 인증서를 교체하면 기존 서명 신원을 계속 사용할 수 없으므로 별도 이전 계획이 필요하다.

### 다른 Mac에서의 검증 절차

1. 이전 ZIP을 전달받아 압축 해제하고 `/Applications/LineLens.app`에 설치한다. 앱 실행 허용이 필요한 경우 해당 앱에 대한 macOS 안내를 따른다.
2. 화면 기록을 최초 승인하고 실제 OCR을 수행한다.
3. 앱을 종료한 뒤 새 ZIP의 앱으로 같은 위치의 기존 앱을 대치한다. TCC 초기화나 화면 기록 항목 삭제를 하지 않는다.
4. 다시 실행해 기존 승인으로 화면 접근·OCR이 가능한지 확인한다. 설정도 유지되는지 확인한다.

다른 Mac에서의 실제 승인 유지, 다운로드한 배포본의 Gatekeeper 동작, Intel 하드웨어 실행은 아직 검증하지 않았다. 같은 인증서의 서명 요구조건을 만족하는지에 대한 검증과 실제 대상 Mac의 권한 유지 검증은 구분한다.

### 배포·교체 검증 결과 (2026-11-02)

- `0.1.0 (build 1)` 통합 배포 ZIP을 만들고, 같은 인증서를 사용한 `0.1.1 (build 2)` 테스트 ZIP을 별도로 생성했다. 당시 만든 `0.1.1`은 `.build/distribution-check` 아래의 검증용 파일이며 배포 버전으로 게시하지 않았다.
- 두 아키텍처의 서명과 이전 앱의 DR 충족 여부, 압축 해제 후 서명·실행 파일·Info.plist·설치 안내 일치 여부가 통과했다.
- ZIP 루트에는 앱·설치 안내·macOS ZIP 메타데이터만 포함되며, 개인 키·키체인·비밀번호가 들어가지 않음을 확인했다. 실제 ZIP 내용으로 버전·Bundle ID·SHA-256도 확인했다.
- 같은 빌드 번호, 잘못된 버전, 없는 이전 앱, 기존 버전 덮어쓰기를 거부했다. Bundle ID가 같아도 임시 서명으로 다시 서명한 업데이트는 거부했다.
- 이 Mac의 별도 설치 경로에서 ZIP을 풀어 앱을 실행한 뒤 종료하고, 같은 위치의 앱을 다음 ZIP의 새 버전으로 교체했다. TCC 초기화·시스템 설정 조작·재승인을 하지 않았다.

```text
0.1.0 build 1: LineLens[56865] ScreenCaptureKit access allowed
0.1.1 build 2: LineLens[56883] ScreenCaptureKit access allowed
```

- 검증용 인스턴스만 종료·정리했으며 기존 개발 앱은 실행 파일 SHA-256·inode·PID가 유지되었다. 기본 `build-app.sh` 명령도 기존 앱을 교체·재시작하지 않고 통과했다.

### 창 직접 선택 배포본 (2026-11-03)

- 창 직접 선택 기능을 추가한 실제 `0.1.1 (build 2)` 배포본은 `dist/releases/0.1.1/LineLens-0.1.1-universal.zip`에 생성했다. 앞서 만든 테스트 ZIP과 구분한다.
- 자동 테스트 22개, Apple Silicon·Intel 컴파일, 두 아키텍처 서명, ZIP 압축 해제 후 검증, 기존 `0.1.0`의 서명 요구조건 충족 여부가 통과했다.
- 현재 Mac에서 실제 클릭 선택·부분 영역 OCR 및 번역·취소·목록 전환을 검증했다. 여러 번의 수정 빌드 교체 후에도 화면 기록 초기화·재승인 없이 실제 ScreenCaptureKit 접근이 성공했다.
- 최종 실행 앱은 같은 소스의 릴리스 빌드이며, 검증용 창을 정리하고 대상이 없는 결과 창을 열어 두었다.

## 업데이트 간 승인 유지 검증 (2026-11-02)

인증서 SHA-1:

```text
E819B2005AA325E604AB3AC15A456032C2A8882D
```

기존 임시 서명에서 전환한 디버그 앱의 화면 기록을 한 번 승인한 뒤, 실제 코드가 다른 릴리스 앱으로 교체했다. 두 빌드의 코드 해시는 다르지만 DR은 동일하다.

```text
debug CDHash:   b1b3f2ddb34eea73c951677a523fe27b8441ec61
release CDHash: 1463165f115faacfc17277adc048696fa1f4bbe3
DR: identifier "com.linelens.app" and certificate leaf = H"e819b2005aa325e604ab3ac15a456032c2a8882d"
```

릴리스 앱 교체 때 `tccutil reset`이나 시스템 설정 재승인을 하지 않았고, 새 프로세스에서 실제 ScreenCaptureKit 접근이 성공했다.

```text
2026-11-02 19:13:19 LineLens[51622] ScreenCaptureKit access allowed  # debug
2026-11-02 19:14:33 LineLens[51843] ScreenCaptureKit access allowed  # release
```

추가로 서로 다른 테스트 실행 파일이 같은 DR을 만족하는지, 설정 스크립트 재실행 시 인증서가 유지되는지, 임시 서명·존재하지 않는 인증서를 지정한 빌드가 기존 앱을 보존하는지 확인했다. 같은 소스 재빌드에서는 실행 파일 SHA-256·inode·실행 중 PID가 유지되었다. 사용자 신뢰 설정의 정책이 `CodeSigning`에 한정되고 키체인 검색 목록도 유지됨을 확인했다. 실제 개인 키 속성도 `extractable=0`, `sensitive=1`, `canSign=1`로 확인했다.

## 이전 임시 서명 복구 검증

- LineLens의 ScreenCapture 승인만 초기화한 뒤 시스템 설정을 새로 열어 현재 앱을 다시 승인했다.
- 이후 두 번의 앱 실행에서 앱의 실제 ScreenCaptureKit 조회가 성공했다.

```text
2026-11-02 17:56:51 LineLens[40276] ScreenCaptureKit access allowed
2026-11-02 17:57:41 LineLens[40514] ScreenCaptureKit access allowed
```

- 재승인 이후 앱 바이너리는 변경하지 않았다.
- 같은 소스를 다시 빌드했을 때 서명 해시, 실행 파일 SHA-256, inode가 모두 유지되었다.
- 자동 테스트 16개와 릴리스 빌드·서명 검증이 통과했다. 실제 영역 선택부터 OCR·번역까지 전체 UI 흐름은 별도 검증 항목이다.

## 참고

- [Apple: 임시 서명과 화면 기록 승인 불일치](https://developer.apple.com/forums/thread/819406)
- [Apple TN2206: 코드 서명과 DR, 자체 서명 인증서](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

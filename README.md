# Cleaner

맥 저장공간 청소 도구다. 빌드 산출물·캐시를 프로젝트 계층별로 찾아 지우고, 큰 폴더를 크기순으로 탐색한다.

현재는 CleanerCore, CLI(스캔, 정리 후보, 삭제, 시스템 항목, 앱 목록·제거), SwiftUI 앱(정리, 큰 폴더 탐색, 앱 목록·제거)까지 구현되어 있다. CLI의 `clean`과 `uninstall`은 `--yes`를 주지 않으면 미리보기만 한다.

## 구성

| 대상 | 역할 |
| --- | --- |
| `CleanerCore` (`Package.swift`) | 디렉터리 스캐너, 크기 트리, 정리 규칙 엔진, 삭제기, 앱 목록. 앱과 CLI가 함께 쓴다. `swift test`로 테스트한다. |
| `cleaner` (`Package.swift`) | CleanerCore를 확인하기 위한 CLI. |
| `Cleaner` 앱 (`Projects/App`, Tuist) | SwiftUI macOS 앱. 저장소 루트의 패키지에서 CleanerCore를 가져다 쓴다. |

앱은 Tuist 프로젝트이고, 코어와 CLI는 SwiftPM 패키지다. Xcode에서 워크스페이스를 열면 앱과 코어 코드를 함께 보고 고칠 수 있다.

## 앱

Tuist 버전은 `mise.toml`(4.197.0)로 고정한다. 처음 한 번은 `mise trust`가 필요할 수 있다.

```bash
tuist generate                 # Cleaner.xcworkspace를 만들고 Xcode로 연다. Cleaner 스킴으로 실행한다
./scripts/build-app.sh         # Release로 빌드해 build/Cleaner.app을 만든다
open build/Cleaner.app
```

- **서명**: `Projects/App/Configuration.xcconfig`가 `Signing.xcconfig`(git 제외)를 선택적으로 불러온다. `Signing.example.xcconfig`를 복사해 `CLEANER_CODE_SIGN_IDENTITY`와 `DEVELOPMENT_TEAM`을 적는다. 고정 인증서로 서명해야 macOS가 다시 빌드한 앱을 같은 앱으로 보고, 한 번 준 권한을 유지한다. 파일이 없으면 ad-hoc 서명이 되어 빌드할 때마다 권한을 새로 묻는다.
- **전체 디스크 접근 권한**: 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한에서 Cleaner를 한 번 켜 두면 폴더마다 허용을 묻지 않는다. 권한이 없으면 데스크탑·문서·다운로드, 다른 앱의 데이터, iCloud, 메일 같은 보호 폴더는 건너뛰고 "권한 필요"로 보여 준다. 권한 없이 그 폴더를 읽으면 macOS가 확인 창을 띄우고, 사용자가 답할 때까지 스캔이 멈추기 때문이다.
- **정리**: 앱을 열면 처음 보이는 화면이다. "프로젝트 폴더"에서 고른 폴더(여러 개 가능, 앱에 저장됨)를 스캔해 빌드 산출물을 찾고, 그 밖의 알려진 캐시 위치와 시뮬레이터 런타임을 함께 찾는다. 위쪽에는 디스크 사용량 막대(고른 항목을 지우면 확실히 비워지는 만큼을 초록색으로 겹침)와 빌드 산출물, 캐시, 판단 필요, 시스템 항목 네 등급의 카드를 둔다. 카드를 누르면 아래 목록이 그 등급으로 바뀌고, 목록은 프로젝트(git 저장소)나 도구 단위로 묶는다. 등급·묶음·항목마다 체크박스로 고른다.
  - **기본 선택**: 빌드 산출물과 캐시는 모두 고르고, 판단 필요와 런타임은 고르지 않는다. 실행 중인 앱의 캐시(Electron 앱 폴더 이름이나 캐시 폴더의 번들 ID로 찾음)는 "실행 중" 표시를 붙이고 고르지 않는다.
  - **지우기**: 아래쪽 "정리…"를 누르면 선택한 개수와 비워질 크기(최소~최대)를 확인한 뒤 지운다. "휴지통으로"를 켜면 휴지통으로 옮긴다. 정리 규칙과 허용 범위, 로그는 CLI와 같다. 런타임처럼 도구가 뒤에서 마저 지우는 항목은 몇 분 뒤 공간이 더 늘어난다고 알린다.
  - **남은 런타임 에셋**: 등록이 풀렸는데 `/System/Library/AssetsV2`에 남은 런타임 에셋을 따로 보여 준다. SIP로 보호되어 앱에서는 지우지 못한다.
  - **권한**: 전체 디스크 접근 권한이 없으면 보호 폴더 안에 있는 프로젝트 폴더는 건너뛰고 화면에 알린다.
- **큰 폴더 탐색**: 홈, 디스크 전체(데이터 볼륨), 고른 폴더를 스캔해 크기순 표로 보여 준다. 폴더를 더블클릭하면 들어가고, 고른 항목은 휴지통으로 옮긴다(홈과 시뮬레이터 폴더 아래만, 홈의 주요 폴더 자체는 막음). 위쪽에는 디스크 사용량, 이 볼륨과 macOS·Preboot·Recovery·VM 볼륨의 크기, 스캔한 크기를 함께 보여 준다.
- **앱**: 열 머리를 눌러 크기, 최소 크기, 추가된 날짜, 마지막 사용일, 이름으로 오름차순·내림차순 정렬한다. 고른 앱은 남은 데이터를 확인한 뒤 휴지통으로 옮긴다. root 소유 앱(App Store 앱 등)은 Finder를 거쳐 옮기므로 Finder가 관리자 암호를 묻는다.
- **확인용 실행 인자**: `-section cleanup|explorer|applications`, `-cleanup YES`(정리 후보를 바로 찾음), `-projectRoots '("~/Projects")'`(프로젝트 폴더 지정), `-cleanupReport <파일>`(정리 후보 요약 JSON), `-cleanupSection cache`(처음 볼 등급), `-expandAll YES`(모든 묶음 펼침), `-scan ~/Projects`(또는 `data`), `-scanReport <파일>`(스캔 요약 JSON), `-snapshot <파일>`(창을 PNG로 저장, 가려진 창은 하얗게 나올 수 있어 `screencapture -l <창 번호>`가 더 확실함), `-uninstallPreview <앱 이름>`(제거 창만 연다).

## 실행

```bash
swift build -c release
.build/release/cleaner scan ~/Projects --depth 2 --top 10
```

디스크 전체를 보려면 데이터 볼륨을 지정한다. `/`는 읽기 전용 시스템 볼륨이라 사용자 데이터가 들어 있지 않다.

```bash
.build/release/cleaner scan /System/Volumes/Data --depth 3
```

정리 후보는 홈을 스캔하고 프로젝트 폴더를 따로 지정해서 본다.

```bash
.build/release/cleaner candidates ~ --project ~/Projects
```

지울 때는 먼저 미리보기를 보고, 같은 명령에 `--yes`를 붙여 실행한다. 기본으로는 빌드 산출물과 캐시만 고른다.

```bash
.build/release/cleaner clean ~ --project ~/Projects --under ~/Projects/MyApp
.build/release/cleaner clean ~ --project ~/Projects --under ~/Projects/MyApp --yes
```

## 시스템 항목 (시스템 설정의 "시스템 데이터")

시스템 설정이 "시스템 데이터"로 묶어 보여 주는 것 중 정리할 수 있는 것을 따로 다룬다. 홈 밖에 있는 위치(`/var/folders/…/C`, `/Library/Developer/CoreSimulator`)는 그 위치만 따로 스캔한다.

| 항목 | 등급 | 정리 방법 |
| --- | --- | --- |
| 시뮬레이터 런타임 | 판단 필요 | `xcrun simctl runtime delete <ID>`. `cleaner clean ~ --runtime 18.2`처럼 버전으로 고른다 |
| 쓸 수 없는 시뮬레이터 | 캐시 | `xcrun simctl delete unavailable` |
| 시뮬레이터 dyld 공유 캐시 | 캐시 | `xcrun simctl runtime dyld_shared_cache remove --all` (root 소유라 직접 지우지 않음) |
| Instruments 캐시, `/var/folders/…/C`의 앱 캐시 | 캐시 | 지움 (`com.apple.*`은 Instruments만) |
| 실기기 설치 차분 캐시 (CoreDevice) | 캐시 | 지움 |
| Electron 앱 캐시 (`Application Support/<앱>/Cache` 등) | 캐시 | 지움 |
| Docker 가상 머신 디스크 | 판단 필요 | `docker system prune --all --force` (Docker Desktop이 켜져 있어야 함) |

공식 명령은 경로를 직접 지우지 않으므로 허용 위치 검사를 하지 않는다. 경로는 표시와 "계획한 그대로인지" 확인에만 쓴다.

- **뒤에서 끝나는 명령**: `simctl runtime delete`는 명령이 바로 끝나도 CoreSimulator가 뒤에서 마저 지운다. 그래서 직후의 여유 공간에는 아직 반영되지 않을 수 있고, 실행 결과에 "뒤에서 처리 중"이라고 표시한다.
- **남은 런타임 에셋**: Cryptex 런타임은 등록이 풀린 뒤에도 내려받은 에셋이 `/System/Library/AssetsV2`에 남을 수 있다(`NeverCollected`이면 macOS가 자동으로 지우지 않음). `cleaner candidates`가 simctl에 등록되지 않은 에셋을 찾아 보여 준다. SIP로 보호된 폴더라 Cleaner나 sudo로는 지울 수 없다.

## 지우는 방식

| 방식 | 언제 | 공간 |
| --- | --- | --- |
| 지움 | 기본 | 바로 비워진다 |
| 휴지통으로 | `--trash` | 휴지통을 비워야 비워진다 |
| 공식 명령 | 규칙에 명령이 있을 때 (XCTestDevices·프리뷰 → `xcrun simctl --set … delete all`, pnpm 저장소 → `pnpm store prune`, Go 모듈 → `go clean -modcache`) | 도구가 정한 만큼 |

- **미리 확인**: 계획 단계에서 허용 범위 밖, 쓰기 권한 없음(관리자 권한 필요), 명령 없음은 건너뛰고, 관련 앱(Xcode, Simulator, Android Studio)이 실행 중이면 경고한다.
- **지우기 직전 재확인**: 경로가 허용 범위 안인지, 부모 경로가 심볼릭 링크로 바뀌지 않았는지(`realpath`), 대상이 스캔할 때와 같은 디렉터리인지(장치 번호와 inode)를 다시 본다. 하나라도 다르면 건너뛴다.
- **안전한 삭제**: `rm -rx`처럼 심볼릭 링크를 따라가지 않고 다른 볼륨으로 내려가지 않는다. 안에 다른 볼륨이 마운트되어 있으면 그 부분은 남기고 실패로 보고한다.
- **허용 범위**: 홈과 `/Library/Developer/CoreSimulator` 아래만 지운다. 홈, `~/Library`, `~/Documents` 같은 주요 폴더 자체는 지우지 않는다.
- **로그**: `~/Library/Logs/Cleaner/cleanup-<시각>.jsonl`에 한 줄에 하나씩 `start`, 항목별 `item`, `finish` 기록을 남긴다. 로그 파일을 만들 수 없으면 아무것도 지우지 않는다.

## 앱 목록과 제거

```bash
.build/release/cleaner apps                          # 크기 내림차순
.build/release/cleaner apps --sort added --asc       # 추가된 날짜 오름차순
.build/release/cleaner apps --sort used --desc       # 마지막 사용 내림차순
.build/release/cleaner uninstall Docker --leftovers  # 미리보기
.build/release/cleaner uninstall Docker --leftovers --yes
```

- **목록**: `/Applications`와 `~/Applications`(그 아래 폴더 2단계까지)의 `.app`을 찾는다. Safari처럼 시스템 볼륨을 가리키는 링크는 지울 수 없어 목록에 넣지 않는다.
- **정렬 기준**: 이름, 크기(최대·최소), 추가된 날짜, 마지막 사용일. 오름차순과 내림차순 모두 된다. 날짜가 없는 앱은 항상 맨 뒤에 둔다.
- **추가된 날짜**: Finder의 "추가된 날짜"다. 마이그레이션으로 한꺼번에 옮긴 앱은 옮긴 날로 나온다. 그런 앱이 절반을 넘으면 목록 아래에 알린다.
- **마지막 사용일**: Spotlight 기록(`kMDItemLastUsedDate`)이다. 기록이 없는 앱이 많다.
- **남은 데이터**: `~/Library` 아래 13개 폴더(Application Support, Caches, Preferences, Containers, Group Containers, Saved Application State 등)에서 번들 ID로 찾는다. 앱 이름과 같은 폴더도 보여 주지만 다른 앱의 것일 수 있어 옮기지 않는다. `com.example.foo.pro`처럼 더 구체적인 번들 ID를 가진 앱이 설치되어 있으면 그 앱의 파일은 뺀다.
- **제거**: 앱과 데이터는 휴지통으로 옮긴다. 앱이 실행 중이면 건너뛰고, root 소유(App Store 앱 등)라 쓰기 권한이 없으면 건너뛴다. 이런 앱은 Finder에서 휴지통으로 옮기면 암호를 묻는다.

## 정리 후보 규칙

규칙은 [DefaultRules.swift](Sources/CleanerCore/Rules/DefaultRules.swift)에 있다.

| 등급 | 뜻 | 예 |
| --- | --- | --- |
| 빌드 산출물 | 다시 빌드하면 생긴다 | `node_modules`, `.build`, `Pods`, `DerivedData` |
| 캐시 | 다시 내려받으면 생긴다 | `~/.npm/_cacache`, `~/Library/Caches/*`, iOS DeviceSupport |
| 판단 필요 | 사람이 보고 정한다. 기본으로 선택하지 않는다 | Python 가상환경, Xcode 아카이브, Android 에뮬레이터 |

- **마커**: 프로젝트 규칙은 이름만으로 판단하지 않는다. `node_modules` 옆에 `package.json`이 있어야 하고, `build`는 옆에 `build.gradle`·`pubspec.yaml`·`*.xcodeproj` 같은 빌드 도구 파일이 있어야 한다. `swift/utils/coverage` 같은 소스 폴더를 지우지 않기 위해서다.
- **프로젝트 폴더 안에서만**: 프로젝트 규칙은 `--project`로 준 폴더 안에서만 찾는다. 숨김 폴더, `~/Library`, 앱 번들 안으로는 들어가지 않는다. `~/.vscode/extensions/*/node_modules`처럼 다시 만들 수 없는 설치물을 보호한다.
- **위치 규칙**: 캐시는 알려진 경로(`~/Library/Caches/*`, `~/.npm/_cacache` 등)에서만 찾는다. `com.apple.*` 캐시는 macOS가 관리하므로 빼고, 스캔도 하지 않는다(다른 규칙이 직접 가리키는 Instruments 캐시는 예외). `~/Library/Caches/com.apple.Music`처럼 열기만 해도 권한 확인 창을 기다리며 멈추는 폴더가 있기 때문이다.
- **git 추적**: git이 추적하는 파일이 든 후보는 "판단 필요"로 내린다. 커밋된 `dist`는 소스일 수 있고, `.build/index-build`처럼 산출물을 실수로 커밋한 경우도 있어 사람이 보게 한다.
- **묶음**: 프로젝트 산출물은 가장 가까운 git 저장소 단위로, 캐시는 도구 단위로 묶는다. Xcode DerivedData는 `info.plist`의 `WorkspacePath`로 원본 프로젝트를 찾고, 원본이 지워졌는지 표시한다.

## 테스트

```bash
swift test
```

`stopsAtMountedVolumes` 테스트는 `hdiutil`로 8MB 디스크 이미지를 만들어 마운트했다가 해제한다.

## 크기를 세는 기준

- **할당 크기**: 논리 크기가 아니라 디스크에 실제로 할당된 크기를 센다. 희소 파일은 작게 잡힌다.
- **마운트 경계**: 시작한 볼륨 밖으로 나가지 않는다. 시뮬레이터 런타임은 `/Library/Developer/CoreSimulator/Volumes` 아래에 별도 볼륨으로 마운트되어 있어서, 경계를 넘으면 같은 데이터를 두 번 센다(`du -sh` 119GB, `du -skx` 22GB).
- **하드링크**: 같은 inode는 한 번만 센다.
- **심볼릭 링크**: 따라가지 않는다.
- **APFS 클론**: 클론은 블록을 공유하므로 할당 크기를 더하면 실제보다 커진다. 그래서 두 값을 함께 보여준다.
  - `totalBytes`: 할당 크기 합계. 지웠을 때 비워질 수 있는 최대치다.
  - `totalUnsharedBytes`: 클론·스냅샷과 공유하지 않는 크기(`ATTR_CMNEXT_PRIVATESIZE`) 합계. 지웠을 때 확실히 비워지는 최소치다.
- **클라우드 전용 파일**: iCloud·File Provider의 dataless 항목은 내려받지 않는다.
- **응답 없는 폴더**: 한 폴더를 15초(`ScanOptions.directoryTimeout`) 안에 읽지 못하면 그 폴더는 "응답 없음"(ETIMEDOUT)으로 남기고 넘어간다. 멈춘 워커 대신 새 워커를 띄워(최대 32개) 나머지 스캔은 계속한다. 권한 확인 창을 기다리며 `open()`이 멈추는 경우를 위한 것이다.

## Full Disk Access

`~/.Trash`, `~/Library/Messages`, 다른 앱의 컨테이너 일부는 Full Disk Access가 없으면 읽을 수 없다. 읽지 못한 경로는 스캔 결과의 `issues`에 남는다. 권한은 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한에서 직접 부여한다.

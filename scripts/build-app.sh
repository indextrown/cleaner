#!/bin/bash
# Tuist로 워크스페이스를 만들고 xcodebuild로 Release 빌드해 build/Cleaner.app에 둔다.
#
# 서명 인증서는 Projects/App/Signing.xcconfig(git 제외)에 적는다. 예시는 Signing.example.xcconfig에 있다.
# 고정 인증서로 서명해야 macOS가 다시 빌드한 앱을 같은 앱으로 보고, 한 번 준 권한(전체 디스크 접근 등)을 유지한다.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f Projects/App/Signing.xcconfig ]; then
    echo "경고: Projects/App/Signing.xcconfig가 없어 ad-hoc으로 서명합니다. 다시 빌드할 때마다 macOS가 권한을 새로 묻습니다." >&2
fi

tuist generate --no-open
xcodebuild -workspace Cleaner.xcworkspace -scheme Cleaner -configuration Release \
    -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' -quiet build

rm -rf build/Cleaner.app
ditto build/DerivedData/Build/Products/Release/Cleaner.app build/Cleaner.app
codesign -dv --verbose=2 build/Cleaner.app 2>&1 | grep -E "^Authority=" | head -n 1 || echo "서명: ad-hoc"
echo "만들었습니다: build/Cleaner.app"

import Darwin

extension [CleanupRule] {
    /// 기본 규칙. 같은 이름(`build`, `target`, `dist`)을 여러 규칙이 다루면 앞에 있는 규칙이 먼저 적용된다.
    public static let defaults: [CleanupRule] = projectRules + locationRules

    private static let projectRules: [CleanupRule] = [
        CleanupRule(
            id: "npm.nodeModules", tool: "npm", title: "npm 의존성", grade: .buildArtifact,
            restore: "npm install (yarn·pnpm install)",
            scope: .project(names: ["node_modules"], markers: [.sibling("package.json")])
        ),
        CleanupRule(
            id: "js.output", tool: "JavaScript", title: "JS 빌드 출력·캐시", grade: .buildArtifact,
            restore: "npm run build",
            scope: .project(
                names: [".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".vite", "dist", "coverage"],
                markers: [.sibling("package.json")]
            )
        ),
        CleanupRule(
            id: "swiftpm.build", tool: "SwiftPM", title: "SwiftPM 빌드", grade: .buildArtifact,
            restore: "swift build 또는 Xcode에서 빌드",
            // Package.swift가 없어도 SwiftPM이 남기는 파일이 안에 있으면 SwiftPM·SourceKit-LSP 산출물이다.
            scope: .project(
                names: [".build"],
                markers: [.sibling("Package.swift"), .inside("workspace-state.json"), .inside("build.db")]
            )
        ),
        CleanupRule(
            id: "xcode.projectBuild", tool: "Xcode", title: "Xcode 빌드", grade: .buildArtifact,
            restore: "Xcode에서 다시 빌드",
            scope: .project(
                names: ["DerivedData", "build"],
                markers: [
                    .siblingSuffix(".xcodeproj"), .siblingSuffix(".xcworkspace"),
                    .sibling("Project.swift"), .sibling("Workspace.swift"),
                ]
            )
        ),
        CleanupRule(
            id: "cocoapods.pods", tool: "CocoaPods", title: "CocoaPods 의존성", grade: .buildArtifact,
            restore: "pod install",
            scope: .project(names: ["Pods"], markers: [.sibling("Podfile")])
        ),
        CleanupRule(
            id: "carthage.checkouts", tool: "Carthage", title: "Carthage 의존성", grade: .buildArtifact,
            restore: "carthage bootstrap",
            scope: .project(names: ["Carthage"], markers: [.sibling("Cartfile")])
        ),
        CleanupRule(
            id: "flutter.build", tool: "Flutter", title: "Flutter 빌드", grade: .buildArtifact,
            restore: "flutter pub get, flutter build",
            scope: .project(names: [".dart_tool", "build"], markers: [.sibling("pubspec.yaml")])
        ),
        CleanupRule(
            id: "gradle.build", tool: "Gradle", title: "Gradle 빌드", grade: .buildArtifact,
            restore: "./gradlew build",
            scope: .project(
                names: ["build", ".gradle", ".cxx", ".externalNativeBuild", ".kotlin"],
                markers: [
                    .sibling("build.gradle"), .sibling("build.gradle.kts"),
                    .sibling("settings.gradle"), .sibling("settings.gradle.kts"),
                ]
            )
        ),
        CleanupRule(
            id: "cargo.target", tool: "Cargo", title: "Rust 빌드", grade: .buildArtifact,
            restore: "cargo build",
            scope: .project(names: ["target"], markers: [.sibling("Cargo.toml")])
        ),
        CleanupRule(
            id: "maven.target", tool: "Maven", title: "Maven 빌드", grade: .buildArtifact,
            restore: "mvn package",
            scope: .project(names: ["target"], markers: [.sibling("pom.xml")])
        ),
        CleanupRule(
            id: "cmake.build", tool: "CMake", title: "CMake 빌드", grade: .buildArtifact,
            restore: "cmake --build",
            scope: .project(names: ["build"], markers: [.sibling("CMakeLists.txt")])
        ),
        CleanupRule(
            id: "pyinstaller.build", tool: "PyInstaller", title: "PyInstaller 빌드", grade: .buildArtifact,
            restore: "pyinstaller <파일>.spec",
            scope: .project(names: ["build", "dist"], markers: [.siblingSuffix(".spec")])
        ),
        CleanupRule(
            id: "python.package", tool: "Python", title: "Python 패키지 빌드", grade: .buildArtifact,
            restore: "python -m build",
            scope: .project(names: ["build", "dist"], markers: [.sibling("pyproject.toml"), .sibling("setup.py")])
        ),
        CleanupRule(
            id: "python.cache", tool: "Python", title: "Python 캐시", grade: .buildArtifact,
            restore: "실행하면 다시 생김",
            scope: .project(names: ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"], markers: [])
        ),
        CleanupRule(
            id: "python.venv", tool: "Python", title: "Python 가상환경", grade: .review,
            restore: "python -m venv 후 pip install -r requirements.txt (패키지 목록이 남아 있어야 함)",
            scope: .project(names: [".venv", "venv"], markers: [.inside("pyvenv.cfg")])
        ),
        // `python -m venv crawling`처럼 이름을 마음대로 붙인 가상환경.
        CleanupRule(
            id: "python.venvAnyName", tool: "Python", title: "Python 가상환경", grade: .review,
            restore: "python -m venv 후 pip install -r requirements.txt (패키지 목록이 남아 있어야 함)",
            scope: .projectContents(childDirectories: ["bin", "lib"], markers: [.inside("pyvenv.cfg")])
        ),
    ]

    private static let locationRules: [CleanupRule] = [
        CleanupRule(
            id: "xcode.derivedData", tool: "Xcode", title: "DerivedData", grade: .buildArtifact,
            restore: "Xcode에서 다시 빌드",
            scope: .contentsOf("Library/Developer/Xcode/DerivedData"),
            linksWorkspace: true
        ),
        CleanupRule(
            id: "xcode.deviceSupport", tool: "Xcode", title: "기기 지원 파일", grade: .cache,
            restore: "기기를 다시 연결하면 Xcode가 다시 만든다",
            scope: .contentsOf("Library/Developer/Xcode/iOS DeviceSupport")
        ),
        CleanupRule(
            id: "xcode.watchDeviceSupport", tool: "Xcode", title: "기기 지원 파일", grade: .cache,
            restore: "기기를 다시 연결하면 Xcode가 다시 만든다",
            scope: .contentsOf("Library/Developer/Xcode/watchOS DeviceSupport")
        ),
        CleanupRule(
            id: "xcode.previews", tool: "Xcode", title: "SwiftUI 프리뷰", grade: .cache,
            restore: "프리뷰를 열면 다시 생김",
            scope: .location("Library/Developer/Xcode/UserData/Previews"),
            command: CleanupCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "--set", "previews", "delete", "all"],
                summary: "프리뷰용 시뮬레이터를 CoreSimulator를 거쳐 지움"
            )
        ),
        CleanupRule(
            id: "xcode.ibSupport", tool: "Xcode", title: "Interface Builder 시뮬레이터", grade: .cache,
            restore: "스토리보드를 열면 다시 생김",
            scope: .location("Library/Developer/Xcode/UserData/IB Support")
        ),
        CleanupRule(
            id: "xcode.documentationCache", tool: "Xcode", title: "문서 캐시", grade: .cache,
            restore: "문서를 열면 다시 내려받음",
            scope: .location("Library/Developer/Xcode/DocumentationCache")
        ),
        CleanupRule(
            id: "xcode.testDevices", tool: "Xcode", title: "병렬 테스트용 시뮬레이터 복제본", grade: .cache,
            restore: "병렬 테스트를 돌리면 다시 생김",
            scope: .location("Library/Developer/XCTestDevices"),
            command: CleanupCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "--set", "testing", "delete", "all"],
                summary: "병렬 테스트용 복제본을 CoreSimulator를 거쳐 지움"
            )
        ),
        CleanupRule(
            id: "simulator.userCaches", tool: "Xcode", title: "시뮬레이터 캐시", grade: .cache,
            restore: "시뮬레이터를 실행하면 다시 생김",
            scope: .location("Library/Developer/CoreSimulator/Caches")
        ),
        // root 소유라 직접 지우려면 관리자 권한이 필요하다. simctl은 CoreSimulator 서비스를 거쳐 지운다.
        CleanupRule(
            id: "simulator.systemCaches", tool: "Xcode", title: "시뮬레이터 dyld 공유 캐시", grade: .cache,
            restore: "시뮬레이터를 처음 켤 때 다시 만든다 (몇 분 걸림)",
            scope: .location("/Library/Developer/CoreSimulator/Caches"),
            command: CleanupCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "runtime", "dyld_shared_cache", "remove", "--all"],
                summary: "모든 런타임의 dyld 공유 캐시를 지움"
            )
        ),
        CleanupRule(
            id: "xcode.coreDeviceDeltas", tool: "Xcode", title: "실기기 설치 차분 캐시", grade: .cache,
            restore: "기기에 앱을 설치하면 다시 생김",
            scope: .location(
                "Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/AppInstallationBinaryDeltas"
            )
        ),
        CleanupRule(
            id: "xcode.archives", tool: "Xcode", title: "아카이브", grade: .review,
            restore: "되돌릴 수 없음. 배포한 빌드의 크래시를 분석하려면 dSYM이 필요하다",
            scope: .contentsOf("Library/Developer/Xcode/Archives")
        ),
        CleanupRule(
            id: "npm.cache", tool: "npm", title: "npm 캐시", grade: .cache,
            restore: "설치할 때 다시 내려받음",
            scope: .location(".npm/_cacache")
        ),
        CleanupRule(
            id: "npm.npx", tool: "npm", title: "npx 캐시", grade: .cache,
            restore: "npx를 실행하면 다시 내려받음",
            scope: .location(".npm/_npx")
        ),
        CleanupRule(
            id: "yarn.cache", tool: "Yarn", title: "Yarn 캐시", grade: .cache,
            restore: "설치할 때 다시 내려받음",
            scope: .location(".yarn/berry/cache")
        ),
        CleanupRule(
            id: "pnpm.store", tool: "pnpm", title: "pnpm 저장소", grade: .cache,
            restore: "설치할 때 다시 내려받음",
            scope: .location("Library/pnpm/store"),
            // 프로젝트의 node_modules가 저장소 파일을 하드링크로 공유하므로 통째로 지우지 않는다.
            command: CleanupCommand(
                executable: "pnpm",
                arguments: ["store", "prune"],
                summary: "어느 프로젝트도 쓰지 않는 패키지만 지움"
            )
        ),
        CleanupRule(
            id: "bun.cache", tool: "Bun", title: "Bun 캐시", grade: .cache,
            restore: "설치할 때 다시 내려받음",
            scope: .location(".bun/install/cache")
        ),
        CleanupRule(
            id: "gradle.caches", tool: "Gradle", title: "Gradle 캐시", grade: .cache,
            restore: "빌드할 때 다시 내려받음",
            scope: .location(".gradle/caches")
        ),
        CleanupRule(
            id: "gradle.wrapper", tool: "Gradle", title: "Gradle 배포판", grade: .cache,
            restore: "./gradlew를 실행하면 다시 내려받음",
            scope: .location(".gradle/wrapper/dists")
        ),
        CleanupRule(
            id: "maven.repository", tool: "Maven", title: "Maven 저장소", grade: .cache,
            restore: "빌드할 때 다시 내려받음",
            scope: .location(".m2/repository")
        ),
        CleanupRule(
            id: "cocoapods.repos", tool: "CocoaPods", title: "CocoaPods 스펙 저장소", grade: .cache,
            restore: "pod install --repo-update",
            scope: .location(".cocoapods/repos")
        ),
        CleanupRule(
            id: "pub.hosted", tool: "Flutter", title: "pub 패키지 캐시", grade: .cache,
            restore: "flutter pub get",
            scope: .location(".pub-cache/hosted")
        ),
        CleanupRule(
            id: "pub.git", tool: "Flutter", title: "pub git 패키지 캐시", grade: .cache,
            restore: "flutter pub get",
            scope: .location(".pub-cache/git")
        ),
        CleanupRule(
            id: "cargo.registry", tool: "Cargo", title: "Cargo 레지스트리", grade: .cache,
            restore: "빌드할 때 다시 내려받음",
            scope: .location(".cargo/registry")
        ),
        CleanupRule(
            id: "go.modules", tool: "Go", title: "Go 모듈 캐시", grade: .cache,
            restore: "빌드할 때 다시 내려받음",
            scope: .location("go/pkg/mod"),
            // 모듈 캐시 파일은 읽기 전용이라 직접 지우면 실패한다.
            command: CleanupCommand(
                executable: "go",
                arguments: ["clean", "-modcache"],
                summary: "Go 모듈 캐시를 지움"
            )
        ),
        CleanupRule(
            id: "android.cache", tool: "Android", title: "Android 캐시", grade: .cache,
            restore: "필요할 때 다시 생김",
            scope: .location(".android/cache")
        ),
        CleanupRule(
            id: "android.avd", tool: "Android", title: "Android 에뮬레이터", grade: .review,
            restore: "에뮬레이터 안의 앱·데이터가 사라진다. Android Studio에서 다시 만든다",
            scope: .contentsOf(".android/avd")
        ),
        CleanupRule(
            id: "android.systemImages", tool: "Android", title: "Android 시스템 이미지", grade: .review,
            restore: "SDK Manager에서 다시 내려받음. 이 이미지를 쓰는 에뮬레이터는 실행되지 않는다",
            scope: .contentsOf("Library/Android/sdk/system-images")
        ),
        CleanupRule(
            id: "tools.cache", tool: "기타 도구 캐시", title: "도구 캐시", grade: .cache,
            restore: "필요할 때 다시 내려받음",
            scope: .contentsOf(".cache")
        ),
        // com.apple.* 캐시는 macOS가 스스로 관리하고, 지우면 iCloud 동기화 같은 시스템 기능이 흔들릴 수 있다.
        CleanupRule(
            id: "apps.cache", tool: "앱 캐시", title: "앱 캐시", grade: .cache,
            restore: "앱을 실행하면 다시 생김",
            scope: .contentsOf("Library/Caches", skippingPrefixes: ["com.apple."])
        ),
        // Electron·Chromium 기반 앱(Discord, VS Code, Notion 등)이 Application Support 안에 두는 캐시.
        CleanupRule(
            id: "apps.electronCache", tool: "앱 캐시", title: "Electron 앱 캐시", grade: .cache,
            restore: "앱을 실행하면 다시 생김 (앱을 끈 뒤 지우는 것이 안전함)",
            scope: .nestedContentsOf(
                "Library/Application Support",
                names: ["Cache", "Code Cache", "GPUCache", "CachedData", "DawnCache", "DawnGraphiteCache",
                        "DawnWebGPUCache", "GrShaderCache", "ShaderCache"]
            )
        ),
        CleanupRule(
            id: "docker.vm", tool: "Docker", title: "Docker 가상 머신 디스크", grade: .review,
            restore: "지운 이미지는 docker pull로 다시 받음. 멈춘 컨테이너와 빌드 캐시도 사라진다",
            scope: .location("Library/Containers/com.docker.docker/Data/vms"),
            command: CleanupCommand(
                executable: "docker",
                arguments: ["system", "prune", "--all", "--force"],
                summary: "쓰지 않는 이미지·멈춘 컨테이너·빌드 캐시를 지움 (Docker Desktop이 켜져 있어야 함, 볼륨은 남김)"
            )
        ),
    ] + userCacheRules

    /// macOS가 사용자별로 두는 캐시 폴더(`/var/folders/…/C`) 규칙. 홈 밖에 있어 따로 스캔해야 찾을 수 있다.
    private static var userCacheRules: [CleanupRule] {
        guard let directory = UserDirectories.cacheDirectory else { return [] }
        return [
            CleanupRule(
                id: "xcode.instrumentsCache", tool: "Xcode", title: "Instruments 캐시", grade: .cache,
                restore: "Instruments를 실행하면 다시 생김",
                scope: .location(directory + "/com.apple.dt.Instruments")
            ),
            CleanupRule(
                id: "system.userCaches", tool: "앱 캐시", title: "임시 앱 캐시 (/var/folders)", grade: .cache,
                restore: "앱을 실행하면 다시 생김",
                scope: .contentsOf(directory, skippingPrefixes: ["com.apple."])
            ),
        ]
    }
}

/// macOS가 사용자마다 따로 정하는 폴더.
public enum UserDirectories {
    /// `/var/folders/…/C`. 심볼릭 링크를 푼 실제 경로(`/private/var/…`)로 돌려준다.
    public static var cacheDirectory: String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0,
              let resolved = realpath(buffer, nil)
        else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

import AppKit
import CleanerCore
import Darwin
import Foundation
import Observation

/// 시스템 데이터의 한 칸이 어떤 성격의 공간인지. 지울 수 있는지와 누가 관리하는지로 나눈다.
enum StorageKind: CaseIterable {
    case cleanable
    case appData
    case developerTools
    case macOS
    case unreadable
    case userFiles

    var title: String {
        switch self {
        case .cleanable: "정리 가능"
        case .appData: "앱 데이터"
        case .developerTools: "개발 도구"
        case .macOS: "macOS 관리"
        case .unreadable: "읽을 수 없음"
        case .userFiles: "시스템 데이터 아님"
        }
    }

    var advice: String {
        switch self {
        case .cleanable: "다시 생기는 것이라 정리 탭에서 지울 수 있음"
        case .appData: "앱이 저장한 데이터. 앱 안에서 지우거나 앱을 지워야 줄어듦"
        case .developerTools: "개발 도구가 설치한 것. 일부는 정리 탭·시스템 항목에서 지울 수 있음"
        case .macOS: "macOS가 관리하는 공간. 직접 지울 수 없음"
        case .unreadable: "전체 디스크 접근 권한으로도 읽을 수 없는 시스템 영역"
        case .userFiles: "설정 앱에서는 문서·응용 프로그램·macOS로 따로 나옴"
        }
    }
}

struct StorageChild: Identifiable {
    let name: String
    let path: String
    let bytes: Int64
    let unsharedBytes: Int64

    var id: String { path }
}

/// 분석 화면의 한 칸. 경로 몇 개를 묶어 크기를 더한다.
struct StorageBucket: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let kind: StorageKind
    /// 설정 앱이 "시스템 데이터"로 묶을 것으로 보이는 칸.
    let isSystemData: Bool
    let note: String
    /// 실제 경로(`/System/Volumes/Data` 접두어 없이). 정리 후보가 이 칸에 드는지 볼 때 쓴다.
    let paths: [String]
    let excludedPaths: [String]
    let bytes: Int64
    let unsharedBytes: Int64
    let children: [StorageChild]
    /// 권한이 없어 일부를 읽지 못했다.
    let isPartiallyMeasured: Bool

    func contains(_ path: String) -> Bool {
        func isWithin(_ folders: [String]) -> Bool {
            folders.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        return isWithin(paths) && !isWithin(excludedPaths)
    }
}

@Observable
@MainActor
final class SystemDataModel {
    static let dataVolume = "/System/Volumes/Data"

    private(set) var buckets: [StorageBucket] = []
    private(set) var volume: VolumeUsage?
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var progress = ExplorerModel.Progress()
    private(set) var hasFullDiskAccess = PrivacyProtection.hasFullDiskAccess
    private(set) var errorMessage: String?

    private var scanTask: Task<Void, Never>?

    var systemBuckets: [StorageBucket] { buckets.filter(\.isSystemData) }
    var otherBuckets: [StorageBucket] { buckets.filter { !$0.isSystemData } }

    func scan() {
        scanTask?.cancel()
        isScanning = true
        errorMessage = nil
        progress = ExplorerModel.Progress()
        hasFullDiskAccess = PrivacyProtection.hasFullDiskAccess
        // 권한 없이 보호 폴더를 읽으면 macOS가 폴더마다 허용 여부를 묻고 답할 때까지 멈춘다.
        let options = ScanOptions(excludedPaths: hasFullDiskAccess ? [] : PrivacyProtection.protectedPaths())
        let scanProgress = ScanProgress()
        scanTask = Task {
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    progress = ExplorerModel.Progress(
                        directories: scanProgress.directories,
                        files: scanProgress.files,
                        bytes: scanProgress.bytes,
                        currentPaths: scanProgress.currentPaths
                    )
                }
            }
            defer { poller.cancel() }
            do {
                let result = try await BackgroundActivity.run("시스템 데이터 분석") {
                    try await DiskScanner(options: options).scan(Self.dataVolume, progress: scanProgress)
                }
                let volume = VolumeUsage(path: Self.dataVolume)
                self.volume = volume
                buckets = Self.buckets(from: result, volume: volume, homeDirectory: NSHomeDirectory())
                hasScanned = true
            } catch is CancellationError {
            } catch {
                errorMessage = Format.describe(error)
            }
            isScanning = false
        }
    }

    func cancel() {
        scanTask?.cancel()
    }

    /// 정리 탭이 찾은 후보 중 이 칸에 드는 것의 크기(최소, 최대).
    func cleanableBytes(in bucket: StorageBucket, entries: [CleanupEntry]) -> (minimum: Int64, maximum: Int64) {
        entries.reduce(into: (minimum: Int64(0), maximum: Int64(0))) { sum, entry in
            guard let path = entry.candidate?.path ?? entry.systemItem?.path,
                  bucket.contains(Self.realPath(path))
            else { return }
            sum.minimum += entry.unsharedBytes
            sum.maximum += entry.bytes
        }
    }

    /// `/System/Volumes/Data/Users/me` → `/Users/me`
    static func realPath(_ path: String) -> String {
        path.hasPrefix(dataVolume + "/") ? String(path.dropFirst(dataVolume.count)) : path
    }

    // MARK: - 칸 나누기

    private struct Spec {
        let id: String
        let title: String
        let systemImage: String
        let kind: StorageKind
        var isSystemData = true
        let note: String
        let paths: [String]
        var excludedPaths: [String] = []
    }

    /// 데이터 볼륨 트리를 설정 앱의 분류에 맞춰 칸으로 나눈다. 칸끼리 겹치지 않게 큰 폴더에서 다른 칸의 경로를 뺀다.
    static func buckets(from result: ScanResult, volume: VolumeUsage?, homeDirectory home: String) -> [StorageBucket] {
        let root = result.root
        func node(_ path: String) -> DirectoryNode? { root.descendant(atPath: dataVolume + path) }
        func children(of path: String) -> [String] {
            node(path)?.children.map { path + "/" + $0.name } ?? []
        }

        let library = home + "/Library"
        let assets = "/System/Library/AssetsV2"
        let runtimeAssets = children(of: assets).filter { $0.hasSuffix("SimulatorRuntime") }
        let hiddenHome = children(of: home).filter {
            let name = ($0 as NSString).lastPathComponent
            return name.hasPrefix(".") && name != ".Trash" && name != ".android"
        }
        let visibleHome = children(of: home).filter {
            let name = ($0 as NSString).lastPathComponent
            return !name.hasPrefix(".") && name != "Library"
        }
        let librarySplit = [
            "/Containers", "/Group Containers", "/Application Support", "/Caches", "/Developer", "/Android",
        ].map { library + $0 }

        let specs: [Spec] = [
            Spec(
                id: "runtimes", title: "시뮬레이터 런타임", systemImage: "iphone.gen3", kind: .developerTools,
                note: "iOS 등 시뮬레이터 운영체제. 등록된 런타임은 정리 탭의 시스템 항목에서 지울 수 있고, 등록이 풀린 남은 에셋은 SIP로 보호돼 macOS만 지움",
                paths: runtimeAssets + ["/Library/Developer/CoreSimulator"]
            ),
            Spec(
                id: "macOSAssets", title: "macOS 내려받기 파일", systemImage: "apple.logo", kind: .macOS,
                note: "Siri·언어 모델·글꼴처럼 macOS가 필요할 때 내려받는 파일",
                paths: ["/System"], excludedPaths: runtimeAssets
            ),
            Spec(
                id: "containers", title: "샌드박스 앱 데이터", systemImage: "shippingbox", kind: .appData,
                note: "App Store 앱 등이 자기 컨테이너에 둔 문서·대화·설정. 그 안의 캐시는 정리 탭에 있음",
                paths: [library + "/Containers", library + "/Group Containers"]
            ),
            Spec(
                id: "applicationSupport", title: "앱 지원 파일", systemImage: "app.badge", kind: .appData,
                note: "앱이 Application Support에 둔 데이터. Electron 앱 캐시는 정리 탭에 있음",
                paths: [library + "/Application Support"]
            ),
            Spec(
                id: "caches", title: "앱 캐시", systemImage: "archivebox", kind: .cleanable,
                note: "앱이 다시 만들 수 있는 캐시. macOS 것(com.apple.*)을 뺀 나머지는 정리 탭에 있음",
                paths: [library + "/Caches"]
            ),
            Spec(
                id: "developer", title: "Xcode·시뮬레이터 기기", systemImage: "hammer", kind: .developerTools,
                note: "DerivedData·기기 지원 파일·프리뷰는 정리 탭의 캐시에, 시뮬레이터 기기는 시스템 항목에 있음",
                paths: [library + "/Developer"]
            ),
            Spec(
                id: "android", title: "Android SDK·에뮬레이터", systemImage: "iphone", kind: .developerTools,
                note: "Android Studio가 설치한 SDK와 에뮬레이터. 시스템 이미지·에뮬레이터는 정리 탭의 판단 필요에 있음",
                paths: [library + "/Android", home + "/.android"]
            ),
            Spec(
                id: "otherLibrary", title: "기타 사용자 라이브러리", systemImage: "books.vertical", kind: .appData,
                note: "설정·로그·메일·메시지 등 ~/Library의 나머지",
                paths: [library], excludedPaths: librarySplit
            ),
            Spec(
                id: "hiddenHome", title: "홈의 숨김 폴더", systemImage: "eye.slash", kind: .developerTools,
                note: "개발 도구가 만든 설정·캐시·내려받은 패키지(.npm, .gradle 등). 캐시 부분은 정리 탭에 있음",
                paths: hiddenHome
            ),
            Spec(
                id: "trash", title: "휴지통", systemImage: "trash", kind: .cleanable,
                note: "Finder에서 휴지통을 비우면 바로 생기는 공간",
                paths: [home + "/.Trash"]
            ),
            Spec(
                id: "homebrew", title: "Homebrew·직접 설치한 도구", systemImage: "terminal", kind: .developerTools,
                note: "brew로 설치한 패키지. 옛 버전은 정리 탭의 시스템 항목(brew cleanup)에 있음",
                paths: ["/opt", "/usr/local"]
            ),
            Spec(
                id: "private", title: "스왑·임시 파일", systemImage: "memorychip", kind: .macOS,
                note: "가상 메모리(스왑)와 임시 파일. 재시동하면 줄어듦. 사용자 임시 캐시 일부는 정리 탭에 있음",
                paths: ["/private"]
            ),
            Spec(
                id: "sharedLibrary", title: "공용 라이브러리", systemImage: "building.columns", kind: .macOS,
                note: "/Library. macOS 업데이트 파일과 여러 앱이 함께 쓰는 지원 파일",
                paths: ["/Library"], excludedPaths: ["/Library/Developer/CoreSimulator"]
            ),
            Spec(
                id: "userFiles", title: "홈 폴더의 파일", systemImage: "folder", kind: .userFiles, isSystemData: false,
                note: "설정 앱에서는 문서·사진·음악 등으로 나옴. 프로젝트의 빌드 산출물도 여기 들어 있음",
                paths: visibleHome
            ),
            Spec(
                id: "applications", title: "응용 프로그램", systemImage: "square.grid.2x2", kind: .userFiles, isSystemData: false,
                note: "설정 앱의 응용 프로그램. 앱 탭에서 지울 수 있음",
                paths: ["/Applications"]
            ),
            Spec(
                id: "otherUsers", title: "다른 사용자·공유 폴더", systemImage: "person.2", kind: .userFiles, isSystemData: false,
                note: "/Users 아래 다른 사용자와 공유 폴더",
                paths: ["/Users"], excludedPaths: [home]
            ),
        ]

        var buckets: [StorageBucket] = specs.compactMap { spec in
            let included = spec.paths.compactMap(node)
            guard !included.isEmpty else { return nil }
            let excluded = spec.excludedPaths.compactMap(node)
            let bytes = included.reduce(0) { $0 + $1.totalBytes } - excluded.reduce(0) { $0 + $1.totalBytes }
            let unshared = included.reduce(0) { $0 + $1.totalUnsharedBytes } - excluded.reduce(0) { $0 + $1.totalUnsharedBytes }
            // 경로가 하나면 그 안을, 여럿이면 경로 자체를 큰 순서로 보여 준다.
            let members = included.count == 1 ? included[0].children : included
            let excludedIDs = Set(excluded.map(ObjectIdentifier.init))
            let children = members
                .filter { !excludedIDs.contains(ObjectIdentifier($0)) && $0.totalBytes >= 100_000_000 }
                .sorted { $0.totalBytes > $1.totalBytes }
                .prefix(10)
                .map { child in
                    StorageChild(
                        name: displayName(child, in: spec.id),
                        path: realPath(child.path),
                        bytes: child.totalBytes,
                        unsharedBytes: child.totalUnsharedBytes
                    )
                }
            let partial = included.contains { $0.status != .scanned || hasUnmeasuredChild($0) }
            return StorageBucket(
                id: spec.id, title: spec.title, systemImage: spec.systemImage, kind: spec.kind,
                isSystemData: spec.isSystemData, note: spec.note, paths: spec.paths, excludedPaths: spec.excludedPaths,
                bytes: max(bytes, 0), unsharedBytes: max(unshared, 0), children: Array(children),
                isPartiallyMeasured: partial
            )
        }

        // 위 칸에 들지 않은 데이터 볼륨 맨 위 폴더(/.fseventsd, /cores 등).
        let covered = buckets.reduce(Int64(0)) { $0 + $1.bytes }
        let coveredUnshared = buckets.reduce(Int64(0)) { $0 + $1.unsharedBytes }
        let leftoverBytes = root.totalBytes - covered
        if leftoverBytes >= 100_000_000 {
            buckets.append(StorageBucket(
                id: "otherLocations", title: "기타 위치", systemImage: "questionmark.folder", kind: .macOS,
                isSystemData: true, note: "데이터 볼륨 맨 위의 나머지 폴더(파일 시스템 기록 등)",
                paths: [], excludedPaths: [], bytes: leftoverBytes,
                unsharedBytes: max(root.totalUnsharedBytes - coveredUnshared, 0), children: [], isPartiallyMeasured: false
            ))
        }

        // 볼륨이 쓴다고 하는 양과 파일을 더한 양의 차이. 파일로 보이지 않는 공간이다.
        if let volume {
            let unseenMaximum = volume.usedBytes - root.totalUnsharedBytes
            if unseenMaximum >= 1_000_000_000 {
                buckets.append(StorageBucket(
                    id: "unreadable", title: "파일로 보이지 않는 공간", systemImage: "lock", kind: .unreadable,
                    isSystemData: true,
                    note: "볼륨 사용량에서 읽은 파일 합계를 뺀 차이. SIP로 막힌 시스템 데이터베이스, Spotlight 색인, 문서 버전 저장소, 파일 시스템 정보 등이라 macOS만 다룸",
                    paths: [], excludedPaths: [], bytes: unseenMaximum,
                    unsharedBytes: max(volume.usedBytes - root.totalBytes, 0), children: [], isPartiallyMeasured: false
                ))
            }
            if volume.otherVolumesBytes > 0 {
                buckets.append(StorageBucket(
                    id: "systemVolumes", title: "macOS 시스템 볼륨", systemImage: "internaldrive", kind: .userFiles,
                    isSystemData: false, note: "설정 앱의 macOS. 시스템·Preboot·Recovery·VM 볼륨이라 지울 수 없음",
                    paths: [], excludedPaths: [], bytes: volume.otherVolumesBytes,
                    unsharedBytes: volume.otherVolumesBytes, children: [], isPartiallyMeasured: false
                ))
            }
        }
        return buckets.sorted { $0.bytes > $1.bytes }
    }

    /// 권한이 없어 건너뛴 폴더가 안에 있는지. 맨 위 두 단계만 본다.
    private static func hasUnmeasuredChild(_ node: DirectoryNode) -> Bool {
        node.children.contains { child in
            child.status == .excluded || child.children.contains { $0.status == .excluded }
        }
    }

    /// 샌드박스 컨테이너 폴더는 번들 ID라서, 설치된 앱이면 앱 이름을 함께 보여 준다.
    private static func displayName(_ node: DirectoryNode, in bucketID: String) -> String {
        guard bucketID == "containers",
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: node.name)
        else { return node.name }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return "\(name) (\(node.name))"
    }
}

import CleanerCore
import Foundation

private func title(of grade: CleanupGrade) -> String {
    switch grade {
    case .buildArtifact: "빌드 산출물 — 다시 빌드하면 생김"
    case .cache: "캐시 — 다시 내려받으면 생김"
    case .review: "판단 필요 — 기본으로 선택하지 않음"
    }
}

private func title(of reason: RejectedMatch.Reason) -> String {
    switch reason {
    case .missingMarker: "마커 없음 (이름만 같음)"
    case .systemManaged: "macOS가 관리함"
    case .recentlyModified: "최근에 바뀜 (쓰는 중일 수 있음)"
    }
}

/// 등급별로, 그 안에서는 프로젝트·도구 묶음별로 큰 것부터 보여준다.
func printCandidates(_ report: CleanupReport, top: Int) {
    for grade in CleanupGrade.allCases {
        let candidates = report.candidates.filter { $0.grade == grade }
        guard !candidates.isEmpty else { continue }
        let bytes = candidates.reduce(0) { $0 + $1.bytes }
        let unsharedBytes = candidates.reduce(0) { $0 + $1.unsharedBytes }
        print("")
        print("■ \(title(of: grade))")
        print("  \(candidates.count)개 · 최대 \(formatBytes(bytes)) · 최소(클론 공유 제외) \(formatBytes(unsharedBytes))")

        let groups = Dictionary(grouping: candidates, by: \.group)
            .map { (group: $0.key, members: $0.value, bytes: $0.value.reduce(0) { $0 + $1.bytes }) }
            .sorted { $0.bytes > $1.bytes }
        for (group, members, groupBytes) in groups {
            let header: String
            var base: String?
            switch group {
            case .project(let root, let isGitRepository):
                header = abbreviate(root) + (isGitRepository ? "  [git]" : "")
                base = root
            case .tool(let name):
                header = name
            }
            print("")
            print("  \(header)  \(formatBytes(groupBytes))")

            for candidate in members.prefix(top) {
                let name = base.map { String(candidate.path.dropFirst($0.count + 1)) } ?? abbreviate(candidate.path)
                var detail = "\(candidate.rule.title) · \(candidate.evidence)"
                if let workspace = candidate.workspacePath {
                    detail += " · 원본 \(abbreviate(workspace))" + (candidate.isWorkspaceMissing ? " (지금은 없음)" : "")
                }
                if candidate.trackedFileCount > 0 {
                    detail += " · git이 추적하는 파일 \(candidate.trackedFileCount.formatted())개 포함"
                }
                print(sizeLine(indent: "    ", candidate.bytes, "\(name)  — \(detail)", unsharedBytes: candidate.unsharedBytes))
            }
            if members.count > top {
                let rest = members.dropFirst(top)
                print(sizeLine(indent: "    ", rest.reduce(0) { $0 + $1.bytes }, "… 외 \(rest.count)개"))
            }
        }
    }

    guard !report.rejected.isEmpty else { return }
    print("")
    print("■ 후보에서 제외")
    for reason in [RejectedMatch.Reason.missingMarker, .systemManaged, .recentlyModified] {
        let items = report.rejected.filter { $0.reason == reason }
        guard !items.isEmpty else { continue }
        print("")
        print("  \(title(of: reason))  \(items.count)개 · \(formatBytes(items.reduce(0) { $0 + $1.node.totalBytes }))")
        for item in items.prefix(top) {
            print(sizeLine(indent: "    ", item.node.totalBytes, abbreviate(item.path)))
        }
        if items.count > top {
            let rest = items.dropFirst(top)
            print(sizeLine(indent: "    ", rest.reduce(0) { $0 + $1.node.totalBytes }, "… 외 \(rest.count)개"))
        }
    }
}

/// 도구가 알려 준 시스템 항목. 크기는 도구가 보고한 값이다.
func printSystemItems(_ items: [SystemItem]) {
    guard !items.isEmpty else { return }
    print("")
    print("■ 시스템 항목 — 도구 명령으로 정리")
    print("  \(items.count)개 · \(formatBytes(items.reduce(0) { $0 + $1.bytes }))")
    for item in items.sorted(by: { $0.bytes > $1.bytes }) {
        let grade = item.grade == .review ? "판단 필요" : item.grade == .cache ? "캐시" : "빌드 산출물"
        print(sizeLine(indent: "    ", item.bytes, "\(item.title)  [\(grade)]"))
        print("                \(item.detail)")
        print("                명령: \(item.command.commandLine)")
        if item.ruleID == "simulator.device" {
            print("                UDID: \(item.selector)")
        }
    }
    print("  런타임을 지우려면: cleaner clean <경로> --runtime <버전>  (예: --runtime 18.2)")
    if let device = items.first(where: { $0.ruleID == "simulator.device" }) {
        print("  시뮬레이터를 지우려면: cleaner clean <경로> --device <UDID>  (예: --device \(device.selector))")
    }
}

/// 등록이 풀렸는데 남은 시뮬레이터 런타임 에셋. Cleaner로는 지울 수 없어 안내만 한다.
func printLeftoverAssets(_ assets: [LeftoverRuntimeAsset]) {
    guard !assets.isEmpty else { return }
    print("")
    print("■ 등록이 풀렸는데 남은 시뮬레이터 런타임 에셋 — macOS만 지울 수 있음")
    print("  \(assets.count)개 · \(formatBytes(assets.reduce(0) { $0 + $1.bytes }))")
    for asset in assets {
        let collection = asset.isNeverCollected ? "  · macOS가 자동으로 지우지 않음(NeverCollected)" : ""
        print(sizeLine(indent: "    ", asset.bytes, "\(asset.platform) \(asset.version) (\(asset.build))\(collection)"))
        print("                \(asset.path)")
    }
    print("  SIP로 보호된 폴더라 Cleaner나 sudo로는 지울 수 없습니다. 런타임을 막 지웠다면 몇 분 뒤 다시 확인하고,")
    print("  계속 남아 있으면 Xcode > 설정 > Components에서 해당 런타임이 보이는지 확인하세요.")
}

/// 한 줄에 하나씩: 종류, 등급 또는 제외 이유, 할당 바이트, 공유 제외 바이트, 규칙 ID, git 추적 파일 수, 경로.
func printCandidatesTSV(
    _ report: CleanupReport,
    systemItems: [SystemItem] = [],
    leftoverAssets: [LeftoverRuntimeAsset] = []
) {
    for asset in leftoverAssets {
        print([
            "leftover", "-", "\(asset.bytes)", "\(asset.bytes)", "simulator.leftoverAsset", "0", asset.path,
        ].joined(separator: "\t"))
    }
    for item in systemItems {
        print([
            "system", "\(item.grade)", "\(item.bytes)", "\(item.bytes)", item.ruleID, "0", item.path,
        ].joined(separator: "\t"))
    }
    for candidate in report.candidates {
        print([
            "candidate", "\(candidate.grade)", "\(candidate.bytes)", "\(candidate.unsharedBytes)",
            candidate.rule.id, "\(candidate.trackedFileCount)", candidate.path,
        ].joined(separator: "\t"))
    }
    for item in report.rejected {
        print([
            "rejected", "\(item.reason)", "\(item.node.totalBytes)", "\(item.node.totalUnsharedBytes)",
            "", "", item.path,
        ].joined(separator: "\t"))
    }
}

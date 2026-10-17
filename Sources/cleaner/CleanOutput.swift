import CleanerCore
import Darwin
import Foundation

private func resolvedPaths(_ paths: [String]) -> [String] {
    paths.map { path in
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// `path`가 `folders` 중 하나이거나 그 아래에 있다.
private func isWithin(_ path: String, _ folders: [String]) -> Bool {
    folders.contains { path == $0 || path.hasPrefix($0 + "/") }
}

/// 등급, 규칙, 폴더 조건으로 후보를 고른다. 등급을 주지 않으면 빌드 산출물과 캐시만 고른다.
func selectCandidates(_ candidates: [CleanupCandidate], arguments: Arguments) -> [CleanupCandidate] {
    let grades = arguments.grades.isEmpty ? [.buildArtifact, .cache] : arguments.grades
    let folders = resolvedPaths(arguments.under)
    let excluded = resolvedPaths(arguments.excluded)
    return candidates.filter { candidate in
        grades.contains(candidate.grade)
            && (arguments.rules.isEmpty || arguments.rules.contains(candidate.rule.id))
            && (folders.isEmpty || isWithin(candidate.path, folders))
            && !isWithin(candidate.path, excluded)
    }
}

/// 시스템 항목도 같은 조건으로 고른다. 런타임은 판단 필요 등급이라 `--grade review`를 줘야 들어온다.
func selectSystemItems(_ items: [SystemItem], arguments: Arguments) -> [SystemItem] {
    let grades = arguments.grades.isEmpty ? [.buildArtifact, .cache] : arguments.grades
    let folders = resolvedPaths(arguments.under)
    let excluded = resolvedPaths(arguments.excluded)
    return items.filter { item in
        grades.contains(item.grade)
            && (arguments.rules.isEmpty || arguments.rules.contains(item.ruleID))
            && (folders.isEmpty || isWithin(item.path, folders))
            && !isWithin(item.path, excluded)
    }
}

private func methodLabel(_ method: DeletionTarget.Method) -> String {
    switch method {
    case .remove: "지움"
    case .moveToTrash: "휴지통으로"
    case .command(let command): "명령: \(command.commandLine)"
    }
}

private func gradeTitle(_ grade: CleanupGrade?) -> String {
    switch grade {
    case .buildArtifact: "빌드 산출물"
    case .cache: "캐시"
    case .review: "판단 필요"
    case nil: "기타"
    }
}

func printPlan(_ plan: DeletionPlan, top: Int) {
    print("삭제 미리보기 — 아직 아무것도 지우지 않았습니다")

    let runnable = plan.runnable
    for grade in [CleanupGrade.buildArtifact, .cache, .review] {
        let items = runnable.filter { $0.target.grade == grade }
            .sorted { $0.target.allocatedBytes > $1.target.allocatedBytes }
        guard !items.isEmpty else { continue }
        let bytes = items.reduce(0) { $0 + $1.target.allocatedBytes }
        print("")
        print("■ \(gradeTitle(grade))  \(items.count)개 · \(formatBytes(bytes))")
        for item in items.prefix(top) {
            let target = item.target
            let label = "\(abbreviate(target.path))  \(methodLabel(target.method))"
            print(sizeLine(indent: "  ", target.allocatedBytes, label, unsharedBytes: target.unsharedBytes))
            for warning in item.warnings {
                print("              ⚠ \(warning.explanation)")
            }
        }
        if items.count > top {
            let rest = items.dropFirst(top)
            print(sizeLine(indent: "  ", rest.reduce(0) { $0 + $1.target.allocatedBytes }, "… 외 \(rest.count)개"))
        }
    }

    let blocked = plan.blocked
    if !blocked.isEmpty {
        print("")
        print("■ 건너뜀  \(blocked.count)개")
        for item in blocked.prefix(top) {
            let reason = item.blocker?.explanation ?? ""
            print(sizeLine(indent: "  ", item.target.allocatedBytes, "\(abbreviate(item.target.path)) — \(reason)"))
        }
        if blocked.count > top {
            print("              … 외 \(blocked.count - top)개")
        }
    }

    print("")
    print("실행하면 \(runnable.count)개 · 확실히 비워지는 최소 \(formatBytes(plan.unsharedBytes)) ~ 최대 \(formatBytes(plan.allocatedBytes))")
}

func printResult(_ result: DeletionResult) {
    let target = result.item.target
    let path = abbreviate(target.path)
    switch result.status {
    case .removed:
        print(sizeLine(indent: "✓ ", target.allocatedBytes, path))
    case .movedToTrash:
        print(sizeLine(indent: "→ ", target.allocatedBytes, "\(path)  (휴지통)"))
    case .commandSucceeded:
        let background = completesInBackground(target) ? " · 뒤에서 처리 중" : ""
        print(sizeLine(indent: "✓ ", target.allocatedBytes, "\(path)  (\(methodLabel(target.method))\(background))"))
    case .skipped(let reason):
        print("–   건너뜀    \(path) — \(reason.explanation)")
    case .failed(let message):
        print("✗   실패      \(path) — \(message)")
    }
}

func printDeletionSummary(_ report: DeletionReport, plan: DeletionPlan) {
    var counts: [String: Int] = [:]
    for result in report.results {
        let key = switch result.status {
        case .removed: "지움"
        case .movedToTrash: "휴지통"
        case .commandSucceeded: "명령"
        case .skipped: "건너뜀"
        case .failed: "실패"
        }
        counts[key, default: 0] += 1
    }
    let summary = ["지움", "휴지통", "명령", "건너뜀", "실패"]
        .compactMap { key in counts[key].map { "\(key) \($0)" } }
        .joined(separator: " · ")
    print("")
    print("완료        \(summary)")
    print("여유 공간   \(formatBytes(report.freeBytesBefore)) → \(formatBytes(report.freeBytesAfter)) "
        + "(\(report.reclaimedBytes >= 0 ? "+" : "")\(formatBytes(report.reclaimedBytes))) — "
        + "예상 최소 \(formatBytes(plan.unsharedBytes)) ~ 최대 \(formatBytes(plan.allocatedBytes))")
    if let logPath = report.logPath {
        print("로그        \(abbreviate(logPath))")
    }
    let background = report.results.filter { $0.status == .commandSucceeded && completesInBackground($0.item.target) }
    if !background.isEmpty {
        print("")
        print("참고        \(background.count)개는 도구가 뒤에서 마저 지웁니다. 위 여유 공간에는 아직 다 반영되지 않았을 수 있습니다.")
        print("            몇 분 뒤 `cleaner candidates ~`로 다시 확인하세요. 시뮬레이터 런타임은 등록이 풀린 뒤에도")
        print("            에셋이 /System/Library/AssetsV2에 남을 수 있으며, 그 목록도 함께 보여 줍니다.")
    }
}

private func completesInBackground(_ target: DeletionTarget) -> Bool {
    if case .command(let command) = target.method { command.completesInBackground } else { false }
}

import CleanerCore
import Darwin
import Foundation

private func formatDate(_ date: Date?) -> String {
    guard let date else { return "기록 없음" }
    return date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
}

private func padLeft(_ text: String, _ width: Int) -> String {
    String(repeating: " ", count: max(0, width - displayWidth(text))) + text
}

private func padRight(_ text: String, _ width: Int) -> String {
    text + String(repeating: " ", count: max(0, width - displayWidth(text)))
}

/// 휴지통으로 옮기려면 앱과 앱이 든 폴더 모두에 쓰기 권한이 있어야 한다. App Store 앱은 보통 root 소유다.
private func needsPassword(_ application: InstalledApplication) -> Bool {
    let parent = (application.path as NSString).deletingLastPathComponent
    return access(application.path, W_OK) != 0 || access(parent, W_OK) != 0
}

func printApplications(_ applications: [InstalledApplication], top: Int?) {
    print([
        padLeft("크기(최대)", 12), padLeft("최소(공유 제외)", 15), padLeft("추가된 날짜", 12),
        padLeft("마지막 사용", 12), padRight("출처", 10), "이름",
    ].joined(separator: "  "))
    for application in applications.prefix(top ?? applications.count) {
        let source = application.isFromAppStore ? "App Store" : "직접 설치"
        var name = application.name + (application.version.map { " \($0)" } ?? "")
        if needsPassword(application) {
            name += "  [옮기려면 암호 필요]"
        }
        print([
            padLeft(formatBytes(application.allocatedBytes), 12),
            padLeft(formatBytes(application.unsharedBytes), 15),
            padLeft(formatDate(application.addedDate), 12),
            padLeft(formatDate(application.lastUsedDate), 12),
            padRight(source, 10),
            name,
        ].joined(separator: "  "))
    }

    let bytes = applications.reduce(0) { $0 + $1.allocatedBytes }
    let unsharedBytes = applications.reduce(0) { $0 + $1.unsharedBytes }
    print("")
    print("앱 \(applications.count)개 · 최대 \(formatBytes(bytes)) · 최소(클론 공유 제외) \(formatBytes(unsharedBytes))")

    // 마이그레이션이나 복원으로 앱을 한꺼번에 옮기면 추가된 날짜가 그날로 모인다.
    let byDay = Dictionary(grouping: applications.compactMap(\.addedDate)) { formatDate($0) }
    if let (day, dates) = byDay.max(by: { $0.value.count < $1.value.count }), dates.count * 2 > applications.count {
        print("앱 \(dates.count)개의 추가된 날짜가 \(day)입니다. 그날 마이그레이션 등으로 한꺼번에 옮겨졌다면 실제 설치일과 다릅니다.")
    }
    let withoutUsage = applications.filter { $0.lastUsedDate == nil }.count
    if withoutUsage > 0 {
        print("앱 \(withoutUsage)개는 Spotlight에 마지막 사용 기록이 없습니다.")
    }
}

/// 경로, 번들 ID, 이름 순서로 앱을 찾는다. 대소문자는 구분하지 않는다.
private func findApplications(_ query: String, in applications: [InstalledApplication]) -> [InstalledApplication] {
    let resolved = realpath(query, nil).map { pointer in
        defer { free(pointer) }
        return String(cString: pointer)
    }
    if let resolved {
        let byPath = applications.filter { $0.path == resolved }
        if !byPath.isEmpty { return byPath }
    }
    let byIdentifier = applications.filter { $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame }
    if !byIdentifier.isEmpty { return byIdentifier }
    let fileName = { (application: InstalledApplication) in
        ((application.path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
    return applications.filter {
        $0.name.caseInsensitiveCompare(query) == .orderedSame || fileName($0).caseInsensitiveCompare(query) == .orderedSame
    }
}

func runApps(_ arguments: Arguments, progress: ScanProgress) async throws {
    let applications = try await ApplicationInventory().applications(progress: progress)
    clearProgressLine()
    printApplications(applications.sorted(by: arguments.sortKey, arguments.sortOrder), top: arguments.top)
}

func runUninstall(_ arguments: Arguments, progress: ScanProgress) async throws {
    let applications = try await ApplicationInventory().applications(progress: progress)
    clearProgressLine()

    var selected: [InstalledApplication] = []
    for query in arguments.positionals {
        let matches = findApplications(query, in: applications)
        guard matches.count == 1, let application = matches.first else {
            if matches.isEmpty {
                writeError("cleaner: '\(query)'에 맞는 앱이 없습니다. cleaner apps로 목록을 보세요.\n")
            } else {
                writeError("cleaner: '\(query)'에 맞는 앱이 여러 개입니다. 경로로 지정하세요:\n")
                matches.forEach { writeError("  \($0.path)\n") }
            }
            exit(1)
        }
        selected.append(application)
    }

    let installedIdentifiers = Set(applications.compactMap(\.bundleIdentifier))
    let finder = LeftoverFinder()
    var leftoversByApplication: [String: [ApplicationLeftover]] = [:]
    var targets: [DeletionTarget] = []
    for application in selected {
        let others = installedIdentifiers.subtracting([application.bundleIdentifier ?? ""])
        let leftovers = await finder.leftovers(for: application, otherBundleIdentifiers: others)
        leftoversByApplication[application.path] = leftovers
        targets.append(DeletionTarget(application: application))
        if arguments.leftovers {
            targets += leftovers.filter { $0.match == .bundleIdentifier }.map { DeletionTarget(leftover: $0, of: application) }
        }
    }

    let plan = DeletionPlanner(policy: .applications()).plan(targets)
    printUninstallPreview(selected, leftovers: leftoversByApplication, plan: plan, includesLeftovers: arguments.leftovers)
    guard arguments.yes else {
        print("실제로 휴지통으로 옮기려면 같은 명령 끝에 --yes를 붙이세요.")
        return
    }
    print("")
    let report = try await Deleter(policy: .applications()).execute(plan) { printResult($0) }
    printDeletionSummary(report, plan: plan)
    print("휴지통으로 옮긴 항목은 휴지통을 비워야 공간이 생깁니다.")
}

private func printUninstallPreview(
    _ applications: [InstalledApplication],
    leftovers: [String: [ApplicationLeftover]],
    plan: DeletionPlan,
    includesLeftovers: Bool
) {
    let planned = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.target.path, $0) })
    func status(_ path: String) -> String {
        guard let item = planned[path] else { return "" }
        if let blocker = item.blocker { return "  — 건너뜀: \(blocker.explanation)" }
        return "  → 휴지통" + item.warnings.map { " · ⚠ \($0.explanation)" }.joined()
    }

    print("앱 제거 미리보기 — 아직 아무것도 옮기지 않았습니다")
    for application in applications {
        print("")
        print("■ \(application.name)\(application.version.map { " \($0)" } ?? "")  (\(application.bundleIdentifier ?? "번들 ID 없음"))")
        print(sizeLine(indent: "  ", application.allocatedBytes, abbreviate(application.path) + status(application.path),
                       unsharedBytes: application.unsharedBytes))

        let found = leftovers[application.path] ?? []
        let byIdentifier = found.filter { $0.match == .bundleIdentifier }
        let byName = found.filter { $0.match == .appName }
        if !byIdentifier.isEmpty {
            let note = includesLeftovers ? "" : " — --leftovers를 주면 함께 옮김"
            print("  남은 데이터 (번들 ID로 찾음)\(note)")
            for leftover in byIdentifier {
                let partial = leftover.isPartiallyMeasured ? "  (일부만 측정됨)" : ""
                print(sizeLine(indent: "    ", leftover.allocatedBytes, abbreviate(leftover.path) + partial + status(leftover.path)))
            }
        }
        if !byName.isEmpty {
            print("  참고 — 이름만 같은 항목 (다른 앱의 것일 수 있어 옮기지 않음)")
            for leftover in byName {
                print(sizeLine(indent: "    ", leftover.allocatedBytes, abbreviate(leftover.path)))
            }
        }
        if found.isEmpty {
            print("  ~/Library에서 남은 데이터를 찾지 못했습니다.")
        }
    }
    print("")
    print("실행하면 \(plan.runnable.count)개를 휴지통으로 옮김 · 크기 \(formatBytes(plan.allocatedBytes)) (휴지통을 비우면 비워짐)")
}

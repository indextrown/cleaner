import CleanerCore
import Darwin
import Foundation

guard let arguments = Arguments(Array(CommandLine.arguments.dropFirst())) else {
    writeError(usage + "\n")
    exit(64)
}

let progress = ScanProgress()
let reporter = isatty(STDERR_FILENO) == 1 ? Task { await reportProgress(progress) } : nil
do {
    switch arguments.command {
    case .apps:
        try await runApps(arguments, progress: progress)
    case .uninstall:
        try await runUninstall(arguments, progress: progress)
    case .scan, .candidates, .clean:
        try await runScanCommand(arguments, progress: progress)
    }
    reporter?.cancel()
} catch {
    reporter?.cancel()
    writeError("\ncleaner: \(describe(error))\n")
    exit(1)
}

func runScanCommand(_ arguments: Arguments, progress: ScanProgress) async throws {
    let scanner = DiskScanner(options: ScanOptions(threadCount: arguments.threads))
    let result = try await scanner.scan(arguments.path, progress: progress)
    reporter?.cancel()
    clearProgressLine()
    let top = arguments.top ?? 10

    switch arguments.command {
    case .scan:
        printScanReport(result, threads: arguments.threads, depth: arguments.depth, top: top)
    case .candidates:
        let start = ContinuousClock.now
        let (report, systemItems) = await collectCleanup(result, arguments: arguments)
        let leftoverAssets = await SimulatorItems.leftoverRuntimeAssets()
        let elapsed = ContinuousClock.now - start
        if arguments.tsv {
            printCandidatesTSV(report, systemItems: systemItems, leftoverAssets: leftoverAssets)
        } else {
            printCandidates(report, top: top)
            printSystemItems(systemItems)
            printLeftoverAssets(leftoverAssets)
            print("")
            print("스캔 \(formatSeconds(result.duration))초 · 규칙 적용·추가 위치·시스템 항목 \(formatSeconds(elapsed))초")
        }
    case .clean:
        let (report, systemItems) = await collectCleanup(result, arguments: arguments)
        let targets = arguments.runtimes.isEmpty
            ? selectCandidates(report.candidates, arguments: arguments).map {
                DeletionTarget(candidate: $0, moveToTrash: arguments.trash)
            } + selectSystemItems(systemItems, arguments: arguments).compactMap(DeletionTarget.init(systemItem:))
            // --runtime을 주면 그 런타임만 고른다. 다른 후보가 함께 지워지지 않게 하기 위해서다.
            : systemItems
                .filter { $0.ruleID == "simulator.runtime" && arguments.runtimes.contains($0.selector) }
                .compactMap(DeletionTarget.init(systemItem:))
        let plan = DeletionPlanner().plan(targets)
        printPlan(plan, top: top)
        guard arguments.yes else {
            print("실제로 지우려면 같은 명령 끝에 --yes를 붙이세요.")
            return
        }
        print("")
        let deletion = try await Deleter().execute(plan) { printResult($0) }
        printDeletionSummary(deletion, plan: plan)
    case .apps, .uninstall:
        break
    }
}

/// 스캔 트리의 후보, 트리 밖에 있는 알려진 캐시 위치의 후보, 도구가 알려 주는 시스템 항목을 모은다.
func collectCleanup(_ result: ScanResult, arguments: Arguments) async -> (CleanupReport, [SystemItem]) {
    let engine = CleanupRuleEngine()
    let projectRoots = arguments.projects.isEmpty ? [result.root.name] : arguments.projects
    let inTree = await GitTrackedFilter().apply(to: engine.evaluate(result, projectRoots: projectRoots))
    let scanner = DiskScanner(options: ScanOptions(threadCount: arguments.threads))
    let outsideTree = await engine.evaluateLocations(outside: result.root.name, scanner: scanner)
    let systemItems = await SimulatorItems.find()
    return (CleanupReport(merging: [inTree, outsideTree]), systemItems)
}

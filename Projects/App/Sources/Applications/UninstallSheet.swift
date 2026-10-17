import CleanerCore
import SwiftUI

/// 고른 앱과 남은 데이터를 확인하고 휴지통으로 옮긴다.
///
/// 번들 ID로 찾은 데이터는 처음부터 고르고, 이름만 같은 항목은 다른 앱의 것일 수 있어 고르지 않는다.
/// 쓰기 권한이 없는 앱(App Store 앱 등)은 Finder를 거쳐 옮기므로 Finder가 관리자 암호를 묻는다.
struct UninstallSheet: View {
    let applications: [InstalledApplication]
    let installedIdentifiers: Set<String>
    let onFinish: (DeletionReport) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var leftovers: [String: [ApplicationLeftover]] = [:]
    @State private var included: Set<String> = []
    @State private var plan: DeletionPlan?
    @State private var isLoading = true
    @State private var isRunning = false
    @State private var report: DeletionReport?
    @State private var failureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(applications.count == 1 ? "\(applications[0].name)을(를) 휴지통으로 옮깁니다" : "앱 \(applications.count)개를 휴지통으로 옮깁니다")
                .font(.title3.bold())
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)

            if isLoading {
                ProgressView("남은 데이터를 찾는 중…")
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if let report {
                resultView(report)
            } else {
                list
            }

            Divider()
            footer
                .padding(16)
        }
        .frame(width: 640, height: 520)
        .task { await loadLeftovers() }
    }

    // MARK: - 목록

    private var list: some View {
        List {
            ForEach(applications) { application in
                Section {
                    itemRow(
                        path: application.path,
                        title: application.path,
                        bytes: application.allocatedBytes,
                        icon: Image(nsImage: IconCache.icon(for: application.path))
                    )
                    let found = leftovers[application.path] ?? []
                    ForEach(found.filter { $0.match == .bundleIdentifier }) { leftover in
                        Toggle(isOn: binding(for: leftover.path)) {
                            itemRow(
                                path: leftover.path,
                                title: "~/Library/" + leftover.location + "/" + (leftover.path as NSString).lastPathComponent,
                                bytes: leftover.allocatedBytes,
                                icon: Image(systemName: leftover.isDirectory ? "folder" : "doc"),
                                note: leftover.isPartiallyMeasured ? "일부만 측정됨" : nil
                            )
                        }
                    }
                    ForEach(found.filter { $0.match == .appName }) { leftover in
                        Toggle(isOn: binding(for: leftover.path)) {
                            itemRow(
                                path: leftover.path,
                                title: "~/Library/" + leftover.location + "/" + (leftover.path as NSString).lastPathComponent,
                                bytes: leftover.allocatedBytes,
                                icon: Image(systemName: "questionmark.folder"),
                                note: "이름만 같음 — 다른 앱의 것일 수 있음"
                            )
                        }
                    }
                    if found.isEmpty {
                        Text("~/Library에서 남은 데이터를 찾지 못했습니다.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("\(application.name)\(application.version.map { " \($0)" } ?? "")")
                }
            }
        }
    }

    private func itemRow(path: String, title: String, bytes: Int64, icon: Image, note: String? = nil) -> some View {
        let item = plan?.items.first { $0.target.path == path }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let blocker = item?.blocker {
                    Label(blocker.explanation, systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                ForEach(item?.warnings.filter { $0 != .spaceFreedOnlyAfterEmptyingTrash } ?? [], id: \.explanation) { warning in
                    Label(warning.explanation, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(Format.bytes(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { included.contains(path) },
            set: { isOn in
                if isOn { included.insert(path) } else { included.remove(path) }
                replan()
            }
        )
    }

    private func resultView(_ report: DeletionReport) -> some View {
        List(report.results, id: \.item.id) { result in
            HStack {
                Image(systemName: result.status.succeeded ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(result.status.succeeded ? .green : .red)
                Text(result.item.target.title)
                Spacer()
                switch result.status {
                case .skipped(let reason):
                    Text(reason.explanation).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).foregroundStyle(.red).lineLimit(2)
                default:
                    Text(Format.bytes(result.item.target.allocatedBytes)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 아래 버튼

    private var footer: some View {
        HStack {
            if report != nil {
                Text("휴지통을 비우면 공간이 생깁니다.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                if let failureMessage {
                    Label(failureMessage, systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let plan {
                    Text("\(plan.runnable.count)개 · \(Format.bytes(plan.allocatedBytes))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("다시 확인") { replan() }
                    .help("앱을 종료한 뒤 누르면 실행 중인지 다시 확인합니다.")
                    .disabled(isLoading || isRunning)
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("휴지통으로 옮기기", role: .destructive) {
                    Task { await execute() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || isRunning || (plan?.runnable.isEmpty ?? true))
            }
        }
    }

    // MARK: - 동작

    private func loadLeftovers() async {
        // 권한이 없으면 다른 앱의 컨테이너 크기를 재다가 macOS가 허용 여부를 묻는 창을 띄운다.
        let finder = LeftoverFinder(measuresProtectedFolders: PrivacyProtection.hasFullDiskAccess)
        for application in applications {
            let others = installedIdentifiers.subtracting([application.bundleIdentifier ?? ""])
            let found = await finder.leftovers(for: application, otherBundleIdentifiers: others)
            leftovers[application.path] = found
            included.formUnion(found.filter { $0.match == .bundleIdentifier }.map(\.path))
        }
        isLoading = false
        replan()
    }

    private func replan() {
        var targets: [DeletionTarget] = []
        for application in applications {
            targets.append(DeletionTarget(application: application))
            for leftover in leftovers[application.path] ?? [] where included.contains(leftover.path) {
                targets.append(DeletionTarget(leftover: leftover, of: application))
            }
        }
        plan = DeletionPlanner(policy: .applications(), authorizesTrash: true).plan(targets)
    }

    private func execute() async {
        guard let plan else { return }
        isRunning = true
        defer { isRunning = false }
        let deleter = Deleter(policy: .applications(), authorizedTrash: WorkspaceTrash())
        do {
            let report = try await BackgroundActivity.run("앱을 휴지통으로 옮기기") {
                try await deleter.execute(plan)
            }
            self.report = report
            onFinish(report)
        } catch {
            // 로그 파일을 만들지 못하면 Deleter는 아무것도 옮기지 않는다.
            failureMessage = "로그를 만들지 못해 옮기지 않았습니다: \(error.localizedDescription)"
        }
    }
}

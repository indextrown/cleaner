import CleanerCore
import SwiftUI

struct ApplicationsView: View {
    @Bindable var model: ApplicationsModel
    @State private var selection: Set<InstalledApplication.ID> = []
    @State private var uninstalling: [InstalledApplication]?

    var body: some View {
        VStack(spacing: 0) {
            if model.applications.isEmpty, model.isLoading {
                ProgressView("앱을 찾고 크기를 재는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.applications.isEmpty, let message = model.errorMessage {
                ContentUnavailableView("앱 목록을 읽지 못했습니다", systemImage: "exclamationmark.triangle", description: Text(message))
            } else {
                table
                if let message = model.lastActionMessage {
                    Divider()
                    Label(message, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("앱")
        .navigationSubtitle(model.applications.isEmpty ? "" : "\(model.applications.count)개 · \(Format.bytes(model.totalBytes))")
        .toolbar {
            Button("새로 고침", systemImage: "arrow.clockwise") {
                Task { await model.load() }
            }
            .disabled(model.isLoading)
            Button("Finder에서 보기", systemImage: "folder") {
                Finder.reveal(Array(selection))
            }
            .disabled(selection.isEmpty)
            Button("휴지통으로 이동…", systemImage: "trash") {
                startUninstall(selection)
            }
            .disabled(selection.isEmpty)
        }
        .task {
            if model.applications.isEmpty { await model.load() }
            // 개발·확인용: `-uninstallPreview <앱 이름>`이면 제거 창을 연다. 버튼을 누르기 전에는 아무것도 옮기지 않는다.
            if let name = UserDefaults.standard.string(forKey: "uninstallPreview"),
               let application = model.applications.first(where: { $0.name == name }) {
                startUninstall([application.id])
            }
        }
        .sheet(item: Binding(
            get: { uninstalling.map(UninstallRequest.init) },
            set: { uninstalling = $0?.applications }
        )) { request in
            UninstallSheet(
                applications: request.applications,
                installedIdentifiers: model.bundleIdentifiers
            ) { report in
                model.finish(report)
                selection.subtract(report.results.filter(\.status.succeeded).map(\.item.target.path))
            }
        }
    }

    private var table: some View {
        Table(model.applications, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("이름", sortUsing: ApplicationComparator(.name)) { application in
                HStack(spacing: 8) {
                    Image(nsImage: IconCache.icon(for: application.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(application.name)
                        .lineLimit(1)
                    if let version = application.version {
                        Text(version)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help(application.path)
            }
            .width(min: 220, ideal: 300)

            TableColumn("크기", sortUsing: ApplicationComparator(.size, order: .reverse)) { application in
                Text(Format.bytes(application.allocatedBytes))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80)

            TableColumn("최소(공유 제외)", sortUsing: ApplicationComparator(.unsharedSize, order: .reverse)) { application in
                Text(Format.bytes(application.unsharedBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 110)

            TableColumn("추가된 날짜", sortUsing: ApplicationComparator(.added, order: .reverse)) { application in
                Text(Format.date(application.addedDate))
                    .help("Finder의 \"추가된 날짜\"입니다. 마이그레이션으로 옮긴 앱은 옮긴 날로 나옵니다.")
            }
            .width(min: 90, ideal: 110)

            TableColumn("마지막 사용", sortUsing: ApplicationComparator(.lastUsed, order: .reverse)) { application in
                Text(Format.date(application.lastUsedDate))
                    .foregroundStyle(application.lastUsedDate == nil ? .tertiary : .primary)
            }
            .width(min: 90, ideal: 110)

            TableColumn("출처") { application in
                Text(application.isFromAppStore ? "App Store" : "직접 설치")
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80)

            TableColumn("상태") { application in
                HStack(spacing: 4) {
                    if model.isRunning(application) {
                        badge("실행 중", color: .green)
                    }
                    if model.needsPassword(application) {
                        badge("암호 필요", color: .orange)
                    }
                }
            }
            .width(min: 80, ideal: 130)
        }
        .onChange(of: model.sortOrder) {
            model.applySort()
        }
        .contextMenu(forSelectionType: InstalledApplication.ID.self) { ids in
            Button("Finder에서 보기") { Finder.reveal(Array(ids)) }
            Divider()
            Button("휴지통으로 이동…") { startUninstall(ids) }
        } primaryAction: { ids in
            Finder.reveal(Array(ids))
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func startUninstall(_ ids: Set<InstalledApplication.ID>) {
        let applications = model.applications.filter { ids.contains($0.id) }
        guard !applications.isEmpty else { return }
        model.refreshRunning()
        uninstalling = applications
    }
}

/// 제거 창을 띄우기 위한 묶음. `sheet(item:)`에 쓰려고 Identifiable로 감싼다.
private struct UninstallRequest: Identifiable {
    let applications: [InstalledApplication]
    var id: [String] { applications.map(\.id) }
}

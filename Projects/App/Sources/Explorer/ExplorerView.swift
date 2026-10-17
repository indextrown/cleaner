import CleanerCore
import SwiftUI

struct ExplorerView: View {
    @Bindable var model: ExplorerModel
    @State private var selection: Set<ExplorerRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\ExplorerRow.bytes, order: .reverse)]
    @State private var pendingPlan: DeletionPlan?
    @State private var choosesFolder = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess {
                fullDiskAccessBanner
                Divider()
            }
            if model.isScanning {
                scanningView
            } else if let current = model.current {
                VolumeSummaryView(model: model)
                Divider()
                BreadcrumbBar(model: model)
                Divider()
                table(for: current)
                statusBar
            } else {
                emptyView
            }
        }
        .navigationTitle("큰 폴더 탐색")
        .navigationSubtitle(model.root?.title ?? "")
        .toolbar { toolbar }
        .fileImporter(isPresented: $choosesFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.scan(.folder(url.path))
            }
        }
        .confirmationDialog(
            "휴지통으로 옮길까요?",
            isPresented: Binding(get: { pendingPlan != nil }, set: { if !$0 { pendingPlan = nil } }),
            presenting: pendingPlan
        ) { plan in
            if !plan.runnable.isEmpty {
                Button("\(plan.runnable.count)개를 휴지통으로 옮기기", role: .destructive) {
                    Task { await model.moveToTrash(plan) }
                    selection = []
                }
            }
            Button("취소", role: .cancel) {}
        } message: { plan in
            Text(confirmationMessage(for: plan))
        }
        .onChange(of: model.current?.path) {
            selection = []
        }
    }

    // MARK: - 표

    private func table(for current: DirectoryNode) -> some View {
        let rows = model.rows(sortedBy: sortOrder)
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("이름", value: \.name, comparator: .localizedStandard) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(row.isDirectory ? Color.accentColor : .secondary)
                        .frame(width: 16)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note = row.note {
                        Text(note)
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 220, ideal: 360)

            TableColumn("크기", value: \.bytes) { row in
                Text(Format.bytes(row.bytes))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 90)

            TableColumn("최소(공유 제외)", value: \.unsharedBytes) { row in
                Text(Format.bytes(row.unsharedBytes))
                    .monospacedDigit()
                    .foregroundStyle(row.unsharedBytes * 10 < row.bytes * 9 ? Color.orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("APFS 클론이나 스냅샷과 공유하지 않는 크기입니다. 지우면 최소한 이만큼은 비워집니다.")
            }
            .width(min: 100, ideal: 110)

            TableColumn("비율", value: \.share) { row in
                ProgressView(value: row.share)
                    .progressViewStyle(.linear)
                    .help(row.share.formatted(.percent.precision(.fractionLength(1))))
            }
            .width(min: 60, ideal: 110)

            TableColumn("파일 수", value: \.sortableFileCount) { row in
                Text(row.fileCount.map { $0.formatted() } ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: ExplorerRow.ID.self) { ids in
            let selected = rows.filter { ids.contains($0.id) }
            if selected.count == 1, let row = selected.first, row.canOpen, case .directory(let node) = row.entry {
                Button("열기") { model.open(node) }
            }
            Button("Finder에서 보기") { Finder.reveal(selected.compactMap(model.path(of:))) }
                .disabled(selected.allSatisfy { !$0.canMoveToTrash })
            Button("경로 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selected.compactMap(model.path(of:)).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("휴지통으로 이동…") { pendingPlan = model.trashPlan(for: selected.filter(\.canMoveToTrash)) }
                .disabled(!selected.contains(where: \.canMoveToTrash))
        } primaryAction: { ids in
            if let row = rows.first(where: { ids.contains($0.id) }), case .directory(let node) = row.entry {
                model.open(node)
            }
        }
    }

    private var selectedRows: [ExplorerRow] {
        model.rows(sortedBy: sortOrder).filter { selection.contains($0.id) }
    }

    private func confirmationMessage(for plan: DeletionPlan) -> String {
        var lines: [String] = []
        if !plan.runnable.isEmpty {
            lines.append("\(plan.runnable.count)개 · \(Format.bytes(plan.allocatedBytes)). 휴지통을 비워야 공간이 생깁니다.")
        }
        for item in plan.blocked {
            lines.append("\(item.target.title): \(item.blocker?.explanation ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 상태

    private var fullDiskAccessBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("전체 디스크 접근 권한이 없습니다")
                    .fontWeight(.semibold)
                Text("데스크탑·문서·다운로드, 다른 앱의 데이터, iCloud, 메일·메시지 폴더는 건너뛰고 \"권한 필요\"로 표시합니다. 권한 없이 읽으면 macOS가 폴더마다 허용 여부를 묻고 스캔이 멈추기 때문입니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("시스템 설정 열기") { Finder.openFullDiskAccessSettings() }
            Button("다시 확인") { model.refreshFullDiskAccess() }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
    }

    private var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("\(model.root?.title ?? "") 스캔 중…")
                .font(.headline)
            Text("폴더 \(model.progress.directories.formatted())개 · 파일 \(model.progress.files.formatted())개 · \(Format.bytes(model.progress.bytes))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(model.progress.currentPaths.prefix(4), id: \.self) { path in
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: 560)
            Button("취소") { model.cancelScan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("어디를 볼까요?", systemImage: "externaldrive")
        } description: {
            if let message = model.errorMessage {
                Text(message)
            } else {
                Text("폴더를 스캔해 무엇이 공간을 차지하는지 크기순으로 보여줍니다. 숨김 폴더와 ~/Library도 포함합니다.")
            }
        } actions: {
            HStack {
                Button("홈 폴더 스캔") { model.scan(.home) }
                    .buttonStyle(.borderedProminent)
                Button("디스크 전체 스캔") { model.scan(.dataVolume) }
                Button("다른 폴더…") { choosesFolder = true }
            }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        let permissionIssues = model.permissionIssueCount
        if permissionIssues > 0 || model.lastActionMessage != nil {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let message = model.lastActionMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .lineLimit(2)
                }
                if permissionIssues > 0 {
                    HStack {
                        Label(
                            "권한이 없어 \(permissionIssues.formatted())곳을 읽지 못했습니다. 크기에 포함되지 않습니다.",
                            systemImage: "lock"
                        )
                        Spacer()
                        Button("전체 디스크 접근 권한 설정…") { Finder.openFullDiskAccessSettings() }
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 도구 막대

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("위로", systemImage: "chevron.left") { model.goUp() }
                .disabled(model.trail.count <= 1)
        }
        ToolbarItemGroup {
            Menu("스캔", systemImage: "magnifyingglass") {
                Button("홈 폴더") { model.scan(.home) }
                Button("디스크 전체") { model.scan(.dataVolume) }
                Button("다른 폴더…") { choosesFolder = true }
            }
            Button("다시 스캔", systemImage: "arrow.clockwise") {
                if let root = model.root { model.scan(root) }
            }
            .disabled(model.root == nil || model.isScanning)
            Button("Finder에서 보기", systemImage: "folder") {
                Finder.reveal(selectedRows.compactMap(model.path(of:)))
            }
            .disabled(selectedRows.allSatisfy { !$0.canMoveToTrash })
            Button("휴지통으로 이동", systemImage: "trash") {
                pendingPlan = model.trashPlan(for: selectedRows.filter(\.canMoveToTrash))
            }
            .disabled(!selectedRows.contains(where: \.canMoveToTrash))
        }
    }
}

private extension ExplorerRow {
    /// 파일 수 열 정렬용. 파일 하나는 1로 본다.
    var sortableFileCount: Int { fileCount ?? 1 }
}

/// 지금 보는 경로. 누르면 그 단계로 돌아간다.
private struct BreadcrumbBar: View {
    let model: ExplorerModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(model.trail.enumerated()), id: \.offset) { depth, node in
                    if depth > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(depth == 0 ? node.name : node.name) { model.go(toDepth: depth) }
                        .buttonStyle(.plain)
                        .foregroundStyle(depth == model.trail.count - 1 ? .primary : .secondary)
                        .fontWeight(depth == model.trail.count - 1 ? .semibold : .regular)
                }
                Spacer(minLength: 12)
                if let current = model.current {
                    Text("\(Format.bytes(current.totalBytes)) · 파일 \(current.totalFileCount.formatted())개")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

/// 볼륨 사용량과 스캔으로 찾은 크기를 나란히 보여준다. 차이는 권한 없는 곳, 시스템 전용 영역, 클론 공유 블록이다.
private struct VolumeSummaryView: View {
    let model: ExplorerModel

    var body: some View {
        if let volume = model.volume, let result = model.result {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("디스크 사용 \(Format.bytes(volume.containerUsedBytes))")
                        .font(.headline)
                    Text("· 남은 공간 \(Format.bytes(volume.availableBytes))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("스캔한 크기 최소 \(Format.bytes(result.root.totalUnsharedBytes)) ~ 최대 \(Format.bytes(result.root.totalBytes))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(volume.containerUsedBytes), total: Double(max(volume.capacityBytes, 1)))
                Text(
                    "이 볼륨(\(volume.mountPoint)) \(Format.bytes(volume.usedBytes)) · "
                        + "macOS·Preboot·Recovery·VM 볼륨 \(Format.bytes(volume.otherVolumesBytes)) (지울 수 없음)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if result.root.name == volume.mountPoint {
                    let unseen = max(volume.usedBytes - result.root.totalUnsharedBytes, 0)
                    Text(
                        "볼륨 전체를 스캔했습니다. 볼륨 사용량과 스캔한 최소 크기의 차이 \(Format.bytes(unseen))는 "
                            + "클론끼리 공유하는 블록, 권한이 없어 읽지 못한 곳(Spotlight 색인 등), 파일 시스템 메타데이터입니다."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }
}

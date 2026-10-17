import AppKit
import CleanerCore
import SwiftUI

struct CleanupView: View {
    @Bindable var model: CleanupModel
    /// 개발·확인용 실행 인자 `-cleanupSection cache`로 처음 볼 등급을 고를 수 있다.
    @State private var section = UserDefaults.standard.string(forKey: "cleanupSection")
        .flatMap { name in CleanupSection.allCases.first { "\($0)" == name } } ?? .buildArtifact
    @State private var expandedGroups: Set<String> = []
    @State private var showsProjectRoots = false
    @State private var pendingPlan: DeletionPlan?

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess {
                fullDiskAccessBanner
                Divider()
            }
            if model.isScanning {
                scanningView
            } else if !model.hasScanned {
                startView
            } else {
                summary
                Divider()
                sectionBar
                Divider()
                sectionContent
                actionBar
            }
        }
        .navigationTitle("정리")
        .navigationSubtitle(searchedPlaces)
        .toolbar {
            ToolbarItemGroup {
                Button { showsProjectRoots = true } label: {
                    Label("프로젝트 폴더", systemImage: "folder.badge.gearshape")
                }
                .labelStyle(.titleAndIcon)
                .help("빌드 산출물을 찾을 폴더를 고릅니다")
                Button { model.refresh() } label: {
                    Label("다시 찾기", systemImage: "arrow.clockwise")
                }
                .labelStyle(.titleAndIcon)
                .help("프로젝트 폴더, 캐시 위치, 시뮬레이터를 다시 확인합니다")
                .disabled(model.isScanning || model.isCleaning)
            }
        }
        .sheet(isPresented: $showsProjectRoots) {
            ProjectRootsView(model: model)
        }
        .confirmationDialog(
            "선택한 항목을 정리할까요?",
            isPresented: Binding(get: { pendingPlan != nil }, set: { if !$0 { pendingPlan = nil } }),
            presenting: pendingPlan
        ) { plan in
            if !plan.runnable.isEmpty {
                Button("\(plan.runnable.count)개 정리", role: .destructive) {
                    Task { await model.clean(plan) }
                }
            }
            Button("취소", role: .cancel) {}
        } message: { plan in
            Text(confirmationMessage(for: plan))
        }
        .onChange(of: model.isScanning) { _, isScanning in
            guard !isScanning else { return }
            // 개발·확인용 실행 인자 `-expandAll YES`면 모든 묶음을 펼친다.
            if UserDefaults.standard.bool(forKey: "expandAll") {
                expandedGroups = Set(CleanupSection.allCases.flatMap { model.groups(in: $0).map(\.id) })
            }
            // 찾기가 끝났는데 보고 있던 등급이 비었으면, 항목이 있는 첫 등급을 보여 준다.
            if model.groups(in: section).isEmpty,
               let first = CleanupSection.allCases.first(where: { !model.groups(in: $0).isEmpty }) {
                section = first
            }
        }
    }

    private var searchedPlaces: String {
        let roots = model.projectRoots.map(CleanupModel.abbreviate)
        let projects = switch roots.count {
        case 0: "프로젝트 폴더 없음"
        case 1, 2: roots.joined(separator: ", ")
        default: "\(roots[0]) 외 \(roots.count - 1)곳"
        }
        return projects + " · 캐시 위치 · 시뮬레이터"
    }

    // MARK: - 요약

    private var summary: some View {
        let selected = model.selectedEntries
        return VStack(alignment: .leading, spacing: 14) {
            if let volume = model.volume {
                DiskUsageBar(
                    volume: volume,
                    reclaimMinimum: selected.reduce(0) { $0 + $1.unsharedBytes },
                    reclaimMaximum: selected.reduce(0) { $0 + $1.bytes }
                )
            }
            HStack(spacing: 10) {
                ForEach(CleanupSection.allCases) { item in
                    let entries = model.entries.filter { $0.section == item }
                    SectionTile(
                        section: item,
                        count: entries.count,
                        selectedCount: entries.filter { model.selection.contains($0.id) }.count,
                        bytes: entries.reduce(0) { $0 + $1.bytes },
                        unsharedBytes: entries.reduce(0) { $0 + $1.unsharedBytes },
                        isCurrent: item == section
                    ) {
                        section = item
                    }
                }
            }
            if !model.skippedRoots.isEmpty {
                Label(
                    "권한이 없어 건너뛴 프로젝트 폴더: " + model.skippedRoots.map(CleanupModel.abbreviate).joined(separator: ", "),
                    systemImage: "lock"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    /// 지금 보는 등급의 설명과 전체 선택. 목록 위에 고정해 두어 스크롤해도 가려지지 않는다.
    private var sectionBar: some View {
        let ids = model.entries.filter { $0.section == section }.map(\.id)
        return HStack(spacing: RowLayout.gap) {
            Color.clear
                .frame(width: RowLayout.chevron, height: 1)
            SelectionBox(state: model.selectionState(of: ids)) { model.toggle(ids) }
                .frame(width: RowLayout.checkbox)
                .disabled(ids.isEmpty)
            Text("\(section.title) 모두 선택")
                .font(.headline)
            Text(section.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Group {
                Button("모두 펼치기") {
                    expandedGroups.formUnion(model.groups(in: section).map(\.id))
                }
                Button("모두 접기") {
                    expandedGroups.subtract(model.groups(in: section).map(\.id))
                }
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, RowLayout.edge)
        .padding(.vertical, 8)
    }

    // MARK: - 목록

    @ViewBuilder
    private var sectionContent: some View {
        let groups = model.groups(in: section)
        let showsLeftovers = section == .system && !model.leftoverAssets.isEmpty
        if groups.isEmpty && !showsLeftovers {
            emptySection
        } else {
            // List의 펼침 화살표는 줄 맨 위에 붙어 체크박스와 어긋나므로, 열 너비를 고정한 줄을 직접 그린다.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        groupRow(group, largestBytes: groups.first?.bytes ?? 1)
                        if expandedGroups.contains(group.id) {
                            ForEach(group.entries) { entry in
                                entryRow(entry)
                            }
                        }
                        Divider()
                            .padding(.leading, RowLayout.edge)
                    }
                    if showsLeftovers {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("등록이 풀렸는데 남은 시뮬레이터 런타임 에셋")
                                .font(.headline)
                            Text("SIP로 보호된 폴더라 Cleaner나 sudo로 지울 수 없습니다. 몇 분 뒤 다시 확인하고, 계속 남으면 Xcode > 설정 > Components를 확인하세요.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, RowLayout.edge)
                        .padding(.top, 18)
                        .padding(.bottom, 6)
                        ForEach(model.leftoverAssets) { asset in
                            leftoverRow(asset)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var emptySection: some View {
        ContentUnavailableView {
            Label("\(section.title) 없음", systemImage: section.systemImage)
        } description: {
            if section == .buildArtifact && model.projectRoots.isEmpty {
                Text("프로젝트 폴더를 추가하면 node_modules, .build, DerivedData 같은 빌드 산출물을 찾습니다.")
            } else {
                Text("이 등급에서 찾은 항목이 없습니다.")
            }
        } actions: {
            if section == .buildArtifact {
                Button("프로젝트 폴더 설정…") { showsProjectRoots = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupRow(_ group: CleanupGroup, largestBytes: Int64) -> some View {
        let ids = group.entries.map(\.id)
        let isExpanded = expandedGroups.contains(group.id)
        let runningCount = group.entries.filter { $0.runningApplication != nil }.count
        let toggleExpansion = {
            if isExpanded { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
        }
        return HStack(spacing: RowLayout.gap) {
            Button(action: toggleExpansion) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: RowLayout.chevron, height: RowLayout.checkbox)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "접기" : "펼치기")
            SelectionBox(state: model.selectionState(of: ids)) { model.toggle(ids) }
                .frame(width: RowLayout.checkbox)
            GroupIcon(group: group, section: section)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let path = group.path {
                        Text((path as NSString).lastPathComponent)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(CleanupModel.abbreviate((path as NSString).deletingLastPathComponent))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    } else {
                        Text(group.title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                    if let note = group.note {
                        Badge(text: note, color: .secondary)
                    }
                    if runningCount > 0 {
                        Badge(text: "실행 중인 앱 \(runningCount)개", color: .orange)
                    }
                }
                SizeBar(fraction: Double(group.bytes) / Double(max(largestBytes, 1)), tint: section.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(group.bytes))
                    .monospacedDigit()
                Text("\(group.entries.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: RowLayout.size, alignment: .trailing)
        }
        .padding(.horizontal, RowLayout.edge)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleExpansion)
    }

    private func entryRow(_ entry: CleanupEntry) -> some View {
        let path = entry.candidate?.path ?? entry.systemItem?.path
        return HStack(spacing: RowLayout.gap) {
            SelectionBox(state: model.selection.contains(entry.id) ? .all : .none) { model.toggle([entry.id]) }
                .frame(width: RowLayout.icon)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let application = entry.runningApplication {
                        Badge(text: "\(application) 실행 중", color: .orange)
                    }
                }
                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let path {
                Button { Finder.reveal([path]) } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Finder에서 보기")
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(entry.bytes))
                    .monospacedDigit()
                if entry.unsharedBytes * 10 < entry.bytes * 9 {
                    Text("최소 \(Format.bytes(entry.unsharedBytes))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .help("APFS 클론과 공유하는 블록을 뺀 크기입니다. 지우면 최소한 이만큼은 비워집니다.")
                }
            }
            .frame(width: RowLayout.size, alignment: .trailing)
        }
        .padding(.leading, RowLayout.iconLeading)
        .padding(.trailing, RowLayout.edge)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        .contextMenu {
            if let path {
                Button("Finder에서 보기") { Finder.reveal([path]) }
            }
        }
    }

    private func leftoverRow(_ asset: LeftoverRuntimeAsset) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(asset.platform) \(asset.version) (\(asset.build))")
                Text(asset.isNeverCollected ? "macOS가 자동으로 지우지 않도록 표시됨(NeverCollected)" : "macOS가 필요할 때 지울 수 있음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.bytes(asset.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: RowLayout.size, alignment: .trailing)
        }
        .padding(.leading, RowLayout.edge + RowLayout.chevron + RowLayout.gap)
        .padding(.trailing, RowLayout.edge)
        .padding(.vertical, 6)
    }

    // MARK: - 아래 막대

    private var actionBar: some View {
        let selected = model.selectedEntries
        let bytes = selected.reduce(0) { $0 + $1.bytes }
        let unsharedBytes = selected.reduce(0) { $0 + $1.unsharedBytes }
        return VStack(alignment: .leading, spacing: 0) {
            Divider()
            if let message = model.lastActionMessage {
                HStack(alignment: .firstTextBaseline) {
                    Label(message, systemImage: message.hasPrefix("정리 완료") ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(message.hasPrefix("정리 완료") ? Color.green : Color.orange)
                        .lineLimit(2)
                    Spacer()
                    Button("닫기", systemImage: "xmark") { model.lastActionMessage = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.isEmpty ? "선택한 항목 없음" : "\(selected.count)개 선택")
                        .font(.headline)
                    Text(selected.isEmpty
                        ? "목록에서 정리할 항목을 고르세요"
                        : "확보 예상 최소 \(Format.bytes(unsharedBytes)) ~ 최대 \(Format.bytes(bytes))")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("휴지통으로 옮기기", isOn: $model.moveToTrash)
                    .toggleStyle(.checkbox)
                    .help("휴지통으로 옮기면 되돌릴 수 있지만, 휴지통을 비워야 공간이 생깁니다. 도구 명령으로 정리하는 항목은 해당하지 않습니다.")
                Button { pendingPlan = model.plan() } label: {
                    Label(model.isCleaning ? "정리 중…" : "정리하기", systemImage: "trash")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || model.isCleaning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private func confirmationMessage(for plan: DeletionPlan) -> String {
        var lines = ["\(plan.runnable.count)개 · 확실히 비워지는 최소 \(Format.bytes(plan.unsharedBytes)) ~ 최대 \(Format.bytes(plan.allocatedBytes))"]
        let removes = plan.runnable.filter { $0.target.method == .remove }.count
        if removes > 0 {
            lines.append("\(removes)개는 바로 지웁니다. 되돌릴 수 없지만 다시 빌드하거나 내려받으면 생기는 것들입니다.")
        }
        let warnings = Set(plan.runnable.flatMap(\.warnings).filter { $0 != .spaceFreedOnlyAfterEmptyingTrash }.map(\.explanation))
        if !warnings.isEmpty {
            lines.append("주의: " + warnings.sorted().joined(separator: ", "))
        }
        if !plan.blocked.isEmpty {
            lines.append("건너뛰는 항목 \(plan.blocked.count)개: " + plan.blocked.prefix(3).map { "\($0.target.title)(\($0.blocker?.explanation ?? ""))" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 상태

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            Text("전체 디스크 접근 권한이 없어 다른 앱의 데이터(Docker, CoreDevice 캐시 등)와 데스크탑·문서·다운로드 안의 프로젝트는 건너뜁니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("시스템 설정 열기") { Finder.openFullDiskAccessSettings() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private var scanningView: some View {
        VStack(spacing: 20) {
            Text("정리할 것을 찾는 중")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                ForEach(CleanupPhase.allCases, id: \.self) { phase in
                    HStack(spacing: 10) {
                        phaseIcon(phase)
                            .frame(width: 18, height: 18)
                        Text(phase.title)
                            .foregroundStyle(phase.rawValue <= model.phase.rawValue ? .primary : .secondary)
                        if phase == model.phase, !model.phaseDetail.isEmpty {
                            Text(model.phaseDetail)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("폴더 \(model.progress.directories.formatted())개 · 파일 \(model.progress.files.formatted())개 · \(Format.bytes(model.progress.bytes))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(model.progress.currentPaths.prefix(3), id: \.self) { path in
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: 560)
            Button("취소") { model.cancel() }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func phaseIcon(_ phase: CleanupPhase) -> some View {
        if phase.rawValue < model.phase.rawValue {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if phase == model.phase {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
    }

    private var startView: some View {
        ContentUnavailableView {
            Label("정리할 것 찾기", systemImage: "sparkles")
        } description: {
            Text("프로젝트 폴더의 빌드 산출물, 알려진 캐시 위치, 시뮬레이터 런타임을 찾아 등급별로 보여 줍니다. 찾기만 하고, 지우는 건 직접 골라서 합니다.")
            Text(model.projectRoots.isEmpty
                ? "프로젝트 폴더: 아직 없음"
                : "프로젝트 폴더: " + model.projectRoots.map(CleanupModel.abbreviate).joined(separator: ", "))
        } actions: {
            HStack {
                Button("찾기") { model.refresh() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("프로젝트 폴더 설정…") { showsProjectRoots = true }
                    .controlSize(.large)
            }
        }
    }
}

/// 정리 목록의 열 너비. 등급 막대, 묶음 줄, 항목 줄이 같은 값을 써서 화살표·체크박스·아이콘 열이 세로로 맞는다.
private enum RowLayout {
    static let edge: CGFloat = 16
    static let chevron: CGFloat = 14
    static let checkbox: CGFloat = 20
    static let icon: CGFloat = 24
    static let gap: CGFloat = 8
    static let size: CGFloat = 84
    /// 묶음 아이콘이 시작하는 자리. 펼친 항목의 체크박스를 아이콘과 같은 너비로 여기에 둔다.
    static let iconLeading = edge + chevron + gap + checkbox + gap
}

extension CleanupSection {
    var tint: Color {
        switch self {
        case .buildArtifact: .blue
        case .cache: .teal
        case .review: .orange
        case .system: .purple
        }
    }
}

/// 디스크 사용량 막대. 선택한 항목을 정리하면 확실히 비워지는 만큼을 사용량 끝에 초록색으로 겹쳐 보여 준다.
private struct DiskUsageBar: View {
    let volume: VolumeUsage
    let reclaimMinimum: Int64
    let reclaimMaximum: Int64

    var body: some View {
        let capacity = Double(max(volume.capacityBytes, 1))
        let used = Double(volume.containerUsedBytes)
        let reclaim = Double(min(reclaimMinimum, volume.containerUsedBytes))
        let isLow = Double(volume.availableBytes) / capacity < 0.1
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(FileManager.default.displayName(atPath: "/"), systemImage: "internaldrive")
                    .font(.headline)
                Text("\(Format.bytes(volume.containerUsedBytes)) / \(Format.bytes(volume.capacityBytes)) 사용")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Text("남은 공간 \(Format.bytes(volume.availableBytes))")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(isLow ? Color.red : Color.primary)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(.quaternary)
                    Rectangle().fill(isLow ? Color.red.opacity(0.8) : Color.accentColor)
                        .frame(width: width * used / capacity)
                    Rectangle().fill(Color.green)
                        .frame(width: width * reclaim / capacity)
                        .offset(x: width * (used - reclaim) / capacity)
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text(reclaimMaximum == 0
                    ? "고른 항목이 없습니다"
                    : "고른 항목을 정리하면 최소 \(Format.bytes(reclaimMinimum)) ~ 최대 \(Format.bytes(reclaimMaximum)) 확보")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// 등급 하나의 크기와 선택 수. 누르면 아래 목록이 그 등급으로 바뀐다.
private struct SectionTile: View {
    let section: CleanupSection
    let count: Int
    let selectedCount: Int
    let bytes: Int64
    let unsharedBytes: Int64
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: section.systemImage)
                        .foregroundStyle(section.tint)
                    Text(section.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.bytes(bytes))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    if unsharedBytes * 10 < bytes * 9 {
                        Text("최소 \(Format.bytes(unsharedBytes))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                            .help("APFS 클론과 공유하는 블록을 뺀 크기입니다. 지우면 최소한 이만큼은 비워집니다.")
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Text(count == 0 ? "찾은 것 없음" : "\(count)개 중 \(selectedCount)개 선택")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCurrent ? section.tint.opacity(0.16) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isCurrent ? section.tint.opacity(0.8) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 묶음 아이콘. 프로젝트는 Finder 폴더 아이콘, 앱이 있는 도구는 앱 아이콘, 나머지는 기호로 보여 준다.
private struct GroupIcon: View {
    let group: CleanupGroup
    let section: CleanupSection

    private static let applicationIdentifiers = [
        "Xcode": "com.apple.dt.Xcode",
        "Android": "com.google.android.studio",
        "Docker": "com.docker.docker",
    ]

    var body: some View {
        if let image = image {
            Image(nsImage: image)
                .resizable()
                .frame(width: RowLayout.icon, height: RowLayout.icon)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(section.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: RowLayout.icon, height: RowLayout.icon)
        }
    }

    private var image: NSImage? {
        if let path = group.path { return IconCache.icon(for: path) }
        guard let identifier = Self.applicationIdentifiers[group.title],
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else { return nil }
        return IconCache.icon(for: url.path)
    }

    private var symbol: String {
        switch group.title {
        case "npm", "pnpm", "Yarn", "Bun", "JavaScript": "shippingbox.fill"
        case "Gradle", "Maven", "CMake", "Cargo", "Go", "SwiftPM", "Carthage", "CocoaPods": "cube.box.fill"
        case "Python", "PyInstaller": "chevron.left.forwardslash.chevron.right"
        case "Flutter": "bird.fill"
        case "Xcode": "hammer.fill"
        case "Android": "iphone"
        case "앱 캐시": "square.stack.3d.up.fill"
        case "기타 도구 캐시": "wrench.and.screwdriver.fill"
        default: "folder.fill"
        }
    }
}

/// 묶음 크기를 가장 큰 묶음과 견준 막대.
private struct SizeBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(tint.opacity(0.75))
                .frame(width: max(proxy.size.width * fraction, 3))
        }
        .frame(height: 4)
    }
}

/// 전체·일부·없음 세 상태를 가진 체크박스.
struct SelectionBox: View {
    let state: SelectionState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .all ? "선택됨" : state == .some ? "일부 선택됨" : "선택 안 됨")
    }

    private var symbol: String {
        switch state {
        case .none: "square"
        case .some: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

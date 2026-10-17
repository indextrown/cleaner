import CleanerCore
import SwiftUI

struct SystemDataView: View {
    let model: SystemDataModel
    let cleanup: CleanupModel
    /// 정리 탭으로 옮긴다.
    let openCleanup: () -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess {
                fullDiskAccessBanner
                Divider()
            }
            if model.isScanning {
                scanningView
            } else if let message = model.errorMessage {
                ContentUnavailableView("분석하지 못했습니다", systemImage: "exclamationmark.triangle", description: Text(message))
            } else if !model.hasScanned {
                startView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        summary
                        Divider()
                        sectionHeader("시스템 데이터로 보이는 공간", detail: "설정 앱의 \"시스템 데이터\"에 들어가는 것으로 보이는 칸")
                        ForEach(model.systemBuckets) { bucketRow($0, largest: model.systemBuckets.first?.bytes ?? 1) }
                        sectionHeader("시스템 데이터가 아닌 공간", detail: "설정 앱에서 문서·응용 프로그램·macOS로 따로 나오는 칸")
                            .padding(.top, 12)
                        ForEach(model.otherBuckets) { bucketRow($0, largest: model.otherBuckets.first?.bytes ?? 1) }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .navigationTitle("시스템 데이터")
        .navigationSubtitle("데이터 볼륨 전체를 읽어 나눈 결과")
        .toolbar {
            Button { model.scan() } label: {
                Label("다시 분석", systemImage: "arrow.clockwise")
            }
            .labelStyle(.titleAndIcon)
            .help("데이터 볼륨 전체를 다시 읽습니다")
            .disabled(model.isScanning)
        }
    }

    // MARK: - 요약

    private var summary: some View {
        let buckets = model.systemBuckets
        let minimum = buckets.reduce(0) { $0 + $1.unsharedBytes }
        let maximum = buckets.reduce(0) { $0 + $1.bytes }
        let byKind = Dictionary(grouping: buckets, by: \.kind).mapValues { $0.reduce(0) { $0 + $1.bytes } }
        let kinds = StorageKind.allCases.filter { (byKind[$0] ?? 0) > 0 }
        let cleanable = buckets.reduce(into: (minimum: Int64(0), maximum: Int64(0))) { sum, bucket in
            let bytes = model.cleanableBytes(in: bucket, entries: cleanup.entries)
            sum.minimum += bytes.minimum
            sum.maximum += bytes.maximum
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("시스템 데이터로 보이는 공간")
                    .font(.headline)
                Text(Format.byteRange(minimum: minimum, maximum: maximum))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .help(Format.byteRangeHelp)
                Spacer()
                if let volume = model.volume {
                    Text("볼륨 사용 \(Format.bytes(volume.containerUsedBytes)) / \(Format.bytes(volume.capacityBytes))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(kinds, id: \.self) { kind in
                        Rectangle()
                            .fill(kind.color)
                            .frame(width: max(proxy.size.width * Double(byKind[kind] ?? 0) / Double(max(maximum, 1)) - 1, 2))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            HStack(spacing: 14) {
                ForEach(kinds, id: \.self) { kind in
                    HStack(spacing: 5) {
                        Circle().fill(kind.color).frame(width: 8, height: 8)
                        Text("\(kind.title) \(Format.bytes(byKind[kind] ?? 0))")
                            .monospacedDigit()
                    }
                    .help(kind.advice)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Group {
                if cleanup.hasScanned {
                    HStack(spacing: 8) {
                        Label(
                            "이 중 정리 탭에서 지울 수 있는 것: \(Format.byteRange(minimum: cleanable.minimum, maximum: cleanable.maximum))",
                            systemImage: "sparkles"
                        )
                        .foregroundStyle(.green)
                        Button("정리 탭 열기", action: openCleanup)
                            .buttonStyle(.link)
                    }
                } else {
                    HStack(spacing: 8) {
                        Label("정리 탭에서 찾기를 하면 칸마다 지울 수 있는 양도 보여 줍니다.", systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                        Button("정리할 것 찾기") {
                            cleanup.refresh()
                            openCleanup()
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .font(.callout)
            Label(
                "설정 앱이 어떤 폴더를 시스템 데이터로 치는지는 공개되어 있지 않아 대략적인 분류입니다. 설정 앱 값과 차이가 날 수 있습니다.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .padding(16)
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - 칸

    private enum Column {
        static let edge: CGFloat = 16
        static let chevron: CGFloat = 14
        static let icon: CGFloat = 24
        static let gap: CGFloat = 8
        static let size: CGFloat = 84
        static var childLeading: CGFloat { edge + chevron + gap + icon + gap }
    }

    @ViewBuilder
    private func bucketRow(_ bucket: StorageBucket, largest: Int64) -> some View {
        let isExpanded = expanded.contains(bucket.id)
        let cleanable = model.cleanableBytes(in: bucket, entries: cleanup.entries)
        let toggle = {
            guard !bucket.children.isEmpty else { return }
            if isExpanded { expanded.remove(bucket.id) } else { expanded.insert(bucket.id) }
        }
        HStack(spacing: Column.gap) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: Column.chevron)
                .opacity(bucket.children.isEmpty ? 0 : 1)
            Image(systemName: bucket.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(bucket.kind.color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: Column.icon)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(bucket.title)
                        .fontWeight(.medium)
                    Badge(text: bucket.kind.title, color: bucket.kind.color)
                        .help(bucket.kind.advice)
                    if bucket.isPartiallyMeasured {
                        Badge(text: "권한이 없어 일부만 읽음", color: .orange)
                    }
                }
                Text(bucket.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if cleanable.maximum > 0 {
                    Label(
                        "정리 탭에서 지울 수 있음: \(Format.byteRange(minimum: cleanable.minimum, maximum: cleanable.maximum))",
                        systemImage: "sparkles"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                }
                SizeBar(fraction: Double(bucket.bytes) / Double(max(largest, 1)), tint: bucket.kind.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Format.byteRange(minimum: bucket.unsharedBytes, maximum: bucket.bytes))
                .monospacedDigit()
                .help(Format.byteRangeHelp)
                .fixedSize()
                .frame(minWidth: Column.size, alignment: .trailing)
        }
        .padding(.horizontal, Column.edge)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        if isExpanded {
            ForEach(bucket.children) { child in
                HStack(spacing: Column.gap) {
                    Text(child.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { Finder.reveal([child.path]) } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Finder에서 보기")
                    Text(Format.byteRange(minimum: child.unsharedBytes, maximum: child.bytes))
                        .monospacedDigit()
                        .fixedSize()
                        .frame(minWidth: Column.size, alignment: .trailing)
                }
                .font(.callout)
                .padding(.leading, Column.childLeading)
                .padding(.trailing, Column.edge)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.03))
                .help(child.path)
            }
        }
        Divider()
            .padding(.leading, Column.edge)
    }

    // MARK: - 상태

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            Text("전체 디스크 접근 권한이 없어 다른 앱의 데이터와 데스크탑·문서·다운로드는 읽지 못하고, 그만큼 \"파일로 보이지 않는 공간\"이 커집니다.")
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
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("데이터 볼륨 전체를 읽는 중")
                .font(.title2.weight(.semibold))
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

    private var startView: some View {
        ContentUnavailableView {
            Label("시스템 데이터 살펴보기", systemImage: "chart.pie")
        } description: {
            Text("설정 앱의 \"시스템 데이터\"가 무엇으로 이루어졌는지 데이터 볼륨 전체를 읽어 나눠 보여 줍니다. 칸마다 지울 수 있는지, 누가 관리하는지도 알려 줍니다. 30초쯤 걸립니다.")
        } actions: {
            Button("분석하기") { model.scan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

extension StorageKind {
    var color: Color {
        switch self {
        case .cleanable: .green
        case .appData: .blue
        case .developerTools: .purple
        case .macOS: .gray
        case .unreadable: .brown
        case .userFiles: .teal
        }
    }
}

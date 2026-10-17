import CleanerCore
import SwiftUI

struct RunningView: View {
    let model: RunningModel
    @State private var pendingForceStop: RunningItem?
    @State private var pendingStopAll: RunningItem.Group?

    var body: some View {
        VStack(spacing: 0) {
            if model.hasLoaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let memory = model.memory {
                            MemorySummary(memory: memory)
                            Divider()
                        }
                        ForEach(RunningItem.Group.allCases, id: \.self) { group in
                            section(group)
                        }
                    }
                    .padding(.bottom, 12)
                }
                if let message = model.lastActionMessage {
                    messageBar(message)
                }
            } else {
                ProgressView("실행 중인 것을 찾는 중")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("실행 중")
        .navigationSubtitle("5초마다 새로 고침")
        .toolbar {
            Button { Task { await model.refresh() } } label: {
                Label("새로 고침", systemImage: "arrow.clockwise")
            }
            .labelStyle(.titleAndIcon)
        }
        .task { await model.monitor() }
        .confirmationDialog(
            "\(pendingForceStop?.title ?? "")을(를) 강제 종료할까요?",
            isPresented: Binding(get: { pendingForceStop != nil }, set: { if !$0 { pendingForceStop = nil } }),
            presenting: pendingForceStop
        ) { item in
            Button("강제 종료", role: .destructive) { Task { await model.stop(item, force: true) } }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("저장하지 않은 내용이 사라질 수 있어요.")
        }
        .confirmationDialog(
            "\(pendingStopAll?.title ?? "") \(pendingStopAll.map { model.items(in: $0).count } ?? 0)개를 모두 끌까요?",
            isPresented: Binding(get: { pendingStopAll != nil }, set: { if !$0 { pendingStopAll = nil } }),
            presenting: pendingStopAll
        ) { group in
            Button("모두 끄기", role: .destructive) { Task { await model.stopAll(in: group) } }
            Button("취소", role: .cancel) {}
        } message: { group in
            Text(group.subtitle)
        }
    }

    // MARK: - 묶음

    private func section(_ group: RunningItem.Group) -> some View {
        let items = model.items(in: group)
        let memory = items.compactMap(\.memoryBytes).reduce(0, +)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.title)
                    .font(.headline)
                if !items.isEmpty {
                    Text("\(items.count)개 · 메모리 \(Format.memory(memory))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                if group != .applications, !items.isEmpty {
                    Button("모두 끄기") { pendingStopAll = group }
                        .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)
            if items.isEmpty {
                Text(group.emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else {
                ForEach(items) { item in
                    row(item)
                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
    }

    private func row(_ item: RunningItem) -> some View {
        HStack(spacing: 10) {
            icon(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.memoryBytes.map(Format.memory) ?? "—")
                .monospacedDigit()
                .foregroundStyle(item.memoryBytes == nil ? .secondary : .primary)
                .frame(minWidth: 72, alignment: .trailing)
                .help("활동 모니터의 \"메모리\"와 같은 기준")
            Group {
                if model.stopping.contains(item.id) {
                    ProgressView()
                        .controlSize(.small)
                } else if model.stuck.contains(item.id), item.forceStop != nil {
                    Button("강제 종료") { pendingForceStop = item }
                        .tint(.red)
                } else {
                    Button(item.group == .applications ? "종료" : "끄기") {
                        Task { await model.stop(item) }
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 76)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func icon(_ item: RunningItem) -> some View {
        if let path = item.bundlePath {
            Image(nsImage: IconCache.icon(for: path))
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: item.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tint(item.group).gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: 26, height: 26)
        }
    }

    private func tint(_ group: RunningItem.Group) -> Color {
        switch group {
        case .simulators: .blue
        case .developerTools: .purple
        case .servers: .green
        case .applications: .gray
        }
    }

    private func messageBar(_ message: String) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .lineLimit(2)
                Spacer()
                Button("닫기", systemImage: "xmark") { model.lastActionMessage = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

/// 메모리 사용량과 압박 정도, 스왑 크기.
private struct MemorySummary: View {
    let memory: MemoryStatus

    var body: some View {
        let fraction = Double(memory.usedBytes) / Double(max(memory.physicalBytes, 1))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("메모리", systemImage: "memorychip")
                    .font(.headline)
                Text("\(Format.memory(memory.usedBytes)) / \(Format.memory(memory.physicalBytes)) 사용")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Badge(text: "압박 \(pressureTitle)", color: pressureColor)
                    .help("macOS가 판단한 메모리 압박 정도. 주의·위험이면 앱을 끄는 게 좋아요")
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.quaternary)
                    Rectangle().fill(pressureColor.opacity(0.8))
                        .frame(width: proxy.size.width * min(fraction, 1))
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            Text(swapText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(16)
    }

    private var swapText: String {
        let compressed = "압축 \(Format.memory(memory.compressedBytes))"
        guard memory.swapUsedBytes > 0 else { return "\(compressed) · 스왑 없음" }
        return "\(compressed) · 스왑 \(Format.memory(memory.swapUsedBytes)) 사용 중. 메모리가 모자라 디스크(/System/Volumes/VM)에 내보낸 양이고, 재시동하면 비워져요"
    }

    private var pressureTitle: String {
        switch memory.pressure {
        case .normal: "보통"
        case .warning: "주의"
        case .critical: "위험"
        }
    }

    private var pressureColor: Color {
        switch memory.pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

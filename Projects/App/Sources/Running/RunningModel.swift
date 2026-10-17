import CleanerCore
import Foundation
import Observation

extension RunningItem.Group {
    var title: String {
        switch self {
        case .simulators: "시뮬레이터·에뮬레이터"
        case .developerTools: "개발 도구 백그라운드"
        case .servers: "포트를 연 개발 서버"
        case .applications: "앱"
        }
    }

    var subtitle: String {
        switch self {
        case .simulators: "꺼도 기기 안의 앱과 데이터는 그대로예요"
        case .developerTools: "빌드가 끝나도 남아 메모리를 쓰는 데몬과 컨테이너"
        case .servers: "node·python 등으로 켠 로컬 서버"
        case .applications: "도우미 프로세스와 앱이 띄운 프로세스까지 합친 메모리"
        }
    }

    var emptyText: String {
        switch self {
        case .simulators: "켜진 시뮬레이터나 에뮬레이터가 없어요."
        case .developerTools: "남아 있는 데몬이나 컨테이너가 없어요."
        case .servers: "포트를 열고 기다리는 개발 서버가 없어요."
        case .applications: "실행 중인 앱이 없어요."
        }
    }
}

@Observable
@MainActor
final class RunningModel {
    private(set) var items: [RunningItem] = []
    private(set) var memory: MemoryStatus?
    private(set) var hasLoaded = false
    /// 끄기를 요청하고 꺼지기를 기다리는 항목.
    private(set) var stopping: Set<RunningItem.ID> = []
    /// 끄기를 요청했는데 꺼지지 않은 항목. 강제 종료 버튼을 보여 준다.
    private(set) var stuck: Set<RunningItem.ID> = []
    var lastActionMessage: String?

    func items(in group: RunningItem.Group) -> [RunningItem] {
        items.filter { $0.group == group }
    }

    func refresh() async {
        let applications = RunningApplicationInfo.regularApplications()
        items = await RunningItems.find(applications: applications)
        memory = MemoryStatus.current()
        hasLoaded = true
        stuck.formIntersection(items.map(\.id))
    }

    /// 화면이 보이는 동안 5초마다 새로 읽는다. 화면을 떠나면 `.task`가 취소한다.
    func monitor() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func stop(_ item: RunningItem, force: Bool = false) async {
        guard let action = force ? item.forceStop : item.stop else { return }
        stopping.insert(item.id)
        defer { stopping.remove(item.id) }
        guard await RunningItemStopper.perform(action) else {
            lastActionMessage = "\(item.title)을(를) 끄지 못했습니다."
            await refresh()
            return
        }
        // 꺼지는 데 시간이 걸리므로 잠깐씩 다시 읽어 사라졌는지 본다.
        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(1))
            await refresh()
            if !items.contains(where: { $0.id == item.id }) {
                stuck.remove(item.id)
                lastActionMessage = "\(item.title)을(를) \(force ? "강제로 " : "")껐어요."
                return
            }
        }
        stuck.insert(item.id)
        lastActionMessage = item.group == .applications
            ? "\(item.title)이(가) 아직 꺼지지 않았어요. 저장할지 묻고 있을 수 있어요. 필요하면 강제 종료하세요."
            : "\(item.title)이(가) 아직 꺼지지 않았어요. 필요하면 강제 종료하세요."
    }

    func stopAll(in group: RunningItem.Group) async {
        for item in items(in: group) {
            await stop(item)
        }
    }
}

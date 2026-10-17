import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case cleanup
    case systemData
    case explorer
    case applications

    var id: Self { self }

    var title: String {
        switch self {
        case .cleanup: "정리"
        case .systemData: "시스템 데이터"
        case .explorer: "큰 폴더 탐색"
        case .applications: "앱"
        }
    }

    var systemImage: String {
        switch self {
        case .cleanup: "sparkles"
        case .systemData: "chart.pie"
        case .explorer: "externaldrive"
        case .applications: "square.grid.2x2"
        }
    }
}

struct RootView: View {
    @State private var selection: SidebarItem? = .cleanup
    @State private var cleanup = CleanupModel()
    @State private var systemData = SystemDataModel()
    @State private var explorer = ExplorerModel()
    @State private var applications = ApplicationsModel()

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            switch selection ?? .cleanup {
            case .cleanup:
                CleanupView(model: cleanup)
            case .systemData:
                SystemDataView(model: systemData, cleanup: cleanup) { selection = .cleanup }
            case .explorer:
                ExplorerView(model: explorer)
            case .applications:
                ApplicationsView(model: applications)
            }
        }
        .task { applyLaunchArguments() }
    }

    /// 개발·확인용 실행 인자. 예: `open Cleaner.app --args -section applications`, `-scan ~/Projects`
    private func applyLaunchArguments() {
        let defaults = UserDefaults.standard
        if let section = defaults.string(forKey: "section").flatMap(SidebarItem.init(rawValue:)) {
            selection = section
        }
        if let path = defaults.string(forKey: "scan") {
            explorer.scan(path == "data" ? .dataVolume : .folder((path as NSString).expandingTildeInPath))
        }
        // `-cleanup YES`면 정리 후보를 바로 찾는다. `-cleanupReport <파일>`이면 끝난 뒤 요약을 남긴다.
        if defaults.bool(forKey: "cleanup") {
            cleanup.refresh()
        }
        // `-systemData YES`면 시스템 데이터 분석을 바로 시작한다.
        if defaults.bool(forKey: "systemData") {
            systemData.scan()
        }
    }
}

import AppKit

/// 개발·확인용. 실행 인자 `-snapshot <경로>`가 있으면 `-snapshotDelay`초 뒤 앞쪽 창(시트 포함)을 PNG로 저장한다.
/// 자기 창을 그리는 것이라 화면 기록 권한이 필요 없다. `-quitAfterSnapshot YES`면 저장한 뒤 종료한다.
@MainActor
enum DevSnapshot {
    static func scheduleIfRequested() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "snapshot") else { return }
        let delay = defaults.double(forKey: "snapshotDelay")
        Task {
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 3))
            // 다른 앱 뒤에 가려진 창은 SwiftUI가 그리지 않으므로, 찍기 전에 맨 앞으로 올리고 한 번 그릴 시간을 준다.
            NSApp.windows.filter(\.isVisible).forEach { $0.orderFrontRegardless() }
            try? await Task.sleep(for: .seconds(1))
            capture(to: (path as NSString).expandingTildeInPath)
            if defaults.bool(forKey: "quitAfterSnapshot") {
                // 시트가 열려 있으면 NSApp.terminate가 막히므로 바로 끝낸다. 확인용 실행에서만 쓴다.
                exit(0)
            }
        }
    }

    private static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.attachedSheet == nil && $0.sheetParent == nil })
            ?? NSApp.windows.first(where: \.isVisible)
        else { return }
        save(window, to: path)
        if let sheet = window.attachedSheet {
            save(sheet, to: (path as NSString).deletingPathExtension + "-sheet.png")
        }
    }

    private static func save(_ window: NSWindow, to path: String) {
        // 제목 막대와 도구 막대까지 담으려고 contentView의 상위(테마 프레임)를 그린다.
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

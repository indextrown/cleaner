import Darwin
import Foundation

/// macOS 개인정보 보호(TCC)가 앱별로 허락을 받는 위치.
///
/// 전체 디스크 접근 권한이 없는 앱이 이 폴더를 읽으면 macOS가 허용 여부를 묻는 창을 띄우고, 사용자가 답할 때까지
/// 그 스레드가 멈춘다. 그래서 권한이 없으면 스캔에서 빼고 "권한 필요"로 보여준다.
public enum PrivacyProtection {
    /// 앱에 전체 디스크 접근 권한이 있는지. 시스템 TCC 데이터베이스는 이 권한이 있어야 읽히며, 읽어 봐도 창이 뜨지 않는다.
    public static var hasFullDiskAccess: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// 홈 아래 보호 폴더. 데이터 볼륨을 스캔할 때 쓰는 `/System/Volumes/Data` 경로도 함께 돌려준다.
    public static func protectedPaths(homeDirectory: String = NSHomeDirectory()) -> Set<String> {
        let folders = [
            "Desktop", "Documents", "Downloads", "Pictures/Photos Library.photoslibrary",
            "Library/Containers", "Library/Group Containers", "Library/Mobile Documents", "Library/CloudStorage",
            "Library/Mail", "Library/Messages", "Library/Safari", "Library/Calendars", "Library/Reminders",
            "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
            "Library/Application Support/MobileSync", ".Trash",
        ]
        let paths = folders.map { homeDirectory + "/" + $0 }
        return Set(paths + paths.map { "/System/Volumes/Data" + $0 })
    }

    /// `LeftoverFinder`가 크기를 재면 권한 창이 뜨는 `~/Library` 아래 폴더.
    static let protectedLibraryFolders: Set<String> = ["Containers", "Group Containers"]
}

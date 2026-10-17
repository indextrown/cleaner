import Darwin

/// 디렉터리가 계획할 때 본 그 디렉터리인지 확인하는 표지. 같은 경로에 새로 만든 디렉터리는 inode가 다르다.
public struct FileIdentity: Sendable, Hashable {
    public let device: Int32
    public let fileID: UInt64

    public init(device: Int32, fileID: UInt64) {
        self.device = device
        self.fileID = fileID
    }
}

/// 도구가 제공하는 정리 명령. 경로를 직접 지우는 대신 실행한다.
public struct CleanupCommand: Sendable, Hashable {
    /// 절대 경로, 또는 PATH에서 찾을 실행 파일 이름.
    public let executable: String
    public let arguments: [String]
    /// 명령이 하는 일. 미리보기에 보여준다.
    public let summary: String
    /// 명령은 바로 끝나지만 실제 삭제는 도구가 뒤에서 마저 한다(시뮬레이터 런타임 삭제 등).
    /// 그래서 명령이 끝난 직후에는 여유 공간이 늘지 않을 수 있다.
    public let completesInBackground: Bool

    public init(executable: String, arguments: [String], summary: String, completesInBackground: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.summary = summary
        self.completesInBackground = completesInBackground
    }

    public var commandLine: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

/// 지울 대상 하나. 정리 후보뿐 아니라 사용자가 고른 폴더나 앱도 같은 형태로 다룬다.
public struct DeletionTarget: Sendable, Identifiable {
    public enum Method: Sendable, Hashable {
        /// 바로 지운다. 공간이 즉시 비워진다.
        case remove
        /// 휴지통으로 옮긴다. 휴지통을 비우기 전까지 공간은 그대로다.
        case moveToTrash
        /// 도구의 공식 명령을 실행한다. 경로는 직접 건드리지 않는다.
        case command(CleanupCommand)
    }

    public let path: String
    public let identity: FileIdentity
    public let method: Method
    public let title: String
    public let ruleID: String?
    public let grade: CleanupGrade?
    public let allocatedBytes: Int64
    public let unsharedBytes: Int64
    /// 디렉터리면 true, 일반 파일(환경설정 plist 등)이면 false. 지우기 직전에 종류가 바뀌었는지 본다.
    public let isDirectory: Bool
    /// 실행 중이면 경고할 앱의 번들 ID.
    public let conflictingApplications: [String]
    /// true면 관련 앱이 실행 중일 때 경고가 아니라 건너뛴다. 앱 자체나 앱의 데이터를 옮길 때 쓴다.
    public let blocksWhileRunning: Bool

    public var id: String { path }

    public init(
        path: String,
        identity: FileIdentity,
        method: Method,
        title: String,
        ruleID: String? = nil,
        grade: CleanupGrade? = nil,
        allocatedBytes: Int64,
        unsharedBytes: Int64,
        isDirectory: Bool = true,
        conflictingApplications: [String] = [],
        blocksWhileRunning: Bool = false
    ) {
        self.path = path
        self.identity = identity
        self.method = method
        self.title = title
        self.ruleID = ruleID
        self.grade = grade
        self.allocatedBytes = allocatedBytes
        self.unsharedBytes = unsharedBytes
        self.isDirectory = isDirectory
        self.conflictingApplications = conflictingApplications
        self.blocksWhileRunning = blocksWhileRunning
    }
}

extension DeletionTarget {
    /// 도구별로, 실행 중일 때 그 도구의 산출물을 지우면 안 되는 앱.
    static let applicationsByTool: [String: [String]] = [
        "Xcode": ["com.apple.dt.Xcode", "com.apple.iphonesimulator"],
        "시뮬레이터 기기": ["com.apple.iphonesimulator"],
        "CocoaPods": ["com.apple.dt.Xcode"],
        "Gradle": ["com.google.android.studio"],
        "Android": ["com.google.android.studio"],
        "Flutter": ["com.google.android.studio"],
    ]

    /// 정리 후보를 삭제 대상으로 바꾼다. 규칙에 명령이 있으면 명령을, 없으면 `moveToTrash`에 따라 지우거나 옮긴다.
    public init(candidate: CleanupCandidate, moveToTrash: Bool) {
        let method: Method = if let command = candidate.rule.command {
            .command(command)
        } else if moveToTrash {
            .moveToTrash
        } else {
            .remove
        }
        self.init(
            path: candidate.path,
            identity: FileIdentity(device: candidate.device, fileID: candidate.node.fileID),
            method: method,
            title: candidate.rule.title,
            ruleID: candidate.rule.id,
            grade: candidate.grade,
            allocatedBytes: candidate.bytes,
            unsharedBytes: candidate.unsharedBytes,
            conflictingApplications: Self.applicationsByTool[candidate.rule.tool] ?? []
        )
    }
}

/// 정리 후보의 등급. 값이 작을수록 지워도 부담이 적다.
public enum CleanupGrade: Int, Sendable, Comparable, CaseIterable {
    /// 다시 빌드하면 그대로 생기는 산출물.
    case buildArtifact = 0
    /// 다시 내려받으면 생기는 캐시. 시간과 네트워크가 든다.
    case cache = 1
    /// 지우기 전에 사람이 판단해야 한다. 기본으로 선택하지 않는다.
    case review = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 어떤 디렉터리를 정리 후보로 볼지 정한 규칙 하나.
public struct CleanupRule: Sendable, Hashable, Identifiable {
    public enum Scope: Sendable, Hashable {
        /// 프로젝트 폴더 안에서 이름이 `names` 중 하나이고 `markers` 중 하나를 만족하는 디렉터리.
        /// `markers`가 비어 있으면 이름만으로 판단한다.
        case project(names: Set<String>, markers: [Marker])
        /// 프로젝트 폴더 안에서 이름과 상관없이 하위 디렉터리로 `childDirectories`를 모두 가지고
        /// `markers` 중 하나를 만족하는 디렉터리. 이름 규칙에 걸리지 않은 디렉터리에만 적용한다.
        case projectContents(childDirectories: Set<String>, markers: [Marker])
        /// 고정 경로 바로 아래의 디렉터리 각각. 이름이 `skippingPrefixes`로 시작하면 뺀다.
        case contentsOf(String, skippingPrefixes: [String] = [])
        /// 고정 경로 아래 각 폴더 안에서 이름이 `names` 중 하나인 디렉터리.
        /// 예: `~/Library/Application Support/<앱>/Cache`
        case nestedContentsOf(String, names: Set<String>)
        /// 고정 경로 자체.
        case location(String)
    }

    public enum Marker: Sendable, Hashable {
        /// 같은 부모 아래에 이 이름의 항목이 있다.
        case sibling(String)
        /// 같은 부모 아래에 이 확장자로 끝나는 항목이 있다.
        case siblingSuffix(String)
        /// 후보 디렉터리 안에 이 이름의 항목이 있다.
        case inside(String)
    }

    public let id: String
    /// 후보를 만든 도구. 위치 규칙의 후보는 이 이름으로 묶는다.
    public let tool: String
    public let title: String
    public let grade: CleanupGrade
    /// 지운 뒤 다시 만드는 방법.
    public let restore: String
    /// 위치 규칙에서 경로는 `/`로 시작하면 절대 경로, 아니면 홈 기준 경로다.
    public let scope: Scope
    /// Xcode DerivedData처럼 `info.plist`의 `WorkspacePath`로 원본 프로젝트를 알 수 있다.
    public let linksWorkspace: Bool
    /// 경로를 직접 지우지 않고 이 명령으로 정리한다. 도구가 내부 상태를 함께 관리하는 경우에 쓴다.
    public let command: CleanupCommand?

    public init(
        id: String,
        tool: String,
        title: String,
        grade: CleanupGrade,
        restore: String,
        scope: Scope,
        linksWorkspace: Bool = false,
        command: CleanupCommand? = nil
    ) {
        self.id = id
        self.tool = tool
        self.title = title
        self.grade = grade
        self.restore = restore
        self.scope = scope
        self.linksWorkspace = linksWorkspace
        self.command = command
    }
}

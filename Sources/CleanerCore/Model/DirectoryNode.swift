/// 스캔한 디렉터리 하나. 하위 디렉터리는 모두 남기고, 파일은 크기가 큰 것만 이름을 남긴다.
///
/// 스캔 중에는 이 노드를 스택에서 꺼낸 워커 스레드 하나만 값을 쓰고, 합계는 모든 워커가 끝난 뒤에
/// 채운다. 그 뒤로는 화면을 그리는 스레드 하나만 읽고 고치므로(`removeChild` 등) 잠금 없이
/// `@unchecked Sendable`로 둔다.
public final class DirectoryNode: @unchecked Sendable {
    /// 화면에 보여 줄 바로 아래 항목 하나.
    public enum Entry: Sendable, Identifiable {
        case directory(DirectoryNode)
        case file(FileEntry)
        /// 이름을 남기지 않은 작은 파일 전체.
        case smallFiles(count: Int, bytes: Int64, unsharedBytes: Int64)

        public var id: String {
            switch self {
            case .directory(let node): "d/" + node.name
            case .file(let file): "f/" + file.name
            case .smallFiles: "small"
            }
        }

        public var bytes: Int64 {
            switch self {
            case .directory(let node): node.totalBytes
            case .file(let file): file.allocatedBytes
            case .smallFiles(_, let bytes, _): bytes
            }
        }

        public var unsharedBytes: Int64 {
            switch self {
            case .directory(let node): node.totalUnsharedBytes
            case .file(let file): file.unsharedBytes
            case .smallFiles(_, _, let unsharedBytes): unsharedBytes
            }
        }
    }

    public enum Status: Sendable, Equatable {
        case scanned
        case unreadable(errno: Int32)
        /// 다른 볼륨이 마운트된 지점이라 들어가지 않았다.
        case otherVolume
        /// `ScanOptions.excludedPaths`에 있어 들어가지 않았다.
        case excluded
        /// iCloud·File Provider에서 아직 내려받지 않은(dataless) 디렉터리라 들어가지 않았다.
        case cloudOnly
    }

    /// 경로의 마지막 요소. 루트 노드는 절대 경로 전체를 담는다.
    public let name: String
    public private(set) weak var parent: DirectoryNode?
    public internal(set) var status: Status = .scanned
    /// inode 번호. 삭제 직전에 같은 디렉터리인지 확인할 때 쓴다.
    public internal(set) var fileID: UInt64 = 0
    public internal(set) var children: [DirectoryNode] = []
    /// 바로 아래 파일 중 `ScanOptions.largeFileThreshold` 이상인 것.
    public internal(set) var largeFiles: [FileEntry] = []
    /// 바로 아래 파일 전체(작은 파일 포함)의 할당 크기와 개수.
    public internal(set) var ownFileBytes: Int64 = 0
    public internal(set) var ownUnsharedBytes: Int64 = 0
    public internal(set) var ownFileCount = 0
    /// 하위 트리 전체의 할당 크기. 이 트리를 지웠을 때 비워질 수 있는 최대치다.
    public internal(set) var totalBytes: Int64 = 0
    /// 하위 트리에서 클론이나 스냅샷과 공유하지 않는 크기. 이 트리를 지웠을 때 확실히 비워지는 최소치다.
    /// 트리 안의 파일끼리만 공유하는 블록도 함께 지우면 비워지지만, 여기에는 들어가지 않는다.
    public internal(set) var totalUnsharedBytes: Int64 = 0
    public internal(set) var totalFileCount = 0
    public internal(set) var totalDirectoryCount = 0

    init(name: String, parent: DirectoryNode?) {
        self.name = name
        self.parent = parent
    }

    public var path: String {
        var components: [String] = []
        var node: DirectoryNode? = self
        while let current = node {
            components.append(current.name)
            node = current.parent
        }
        let rootPath = components.removeLast()
        guard !components.isEmpty else { return rootPath }
        let relativePath = components.reversed().joined(separator: "/")
        return rootPath == "/" ? "/" + relativePath : rootPath + "/" + relativePath
    }

    /// 이 노드를 루트로 보고 절대 경로에 해당하는 하위 노드를 찾는다.
    public func descendant(atPath path: String) -> DirectoryNode? {
        if path == name { return self }
        let prefix = name == "/" ? "/" : name + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var node = self
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let child = node.children.first(where: { $0.name == component }) else { return nil }
            node = child
        }
        return node
    }

    /// 바로 아래 디렉터리, 큰 파일, 나머지 작은 파일 묶음을 크기가 큰 것부터 돌려준다.
    public var entries: [Entry] {
        var entries = children.map(Entry.directory) + largeFiles.map(Entry.file)
        let smallFileCount = ownFileCount - largeFiles.count
        if smallFileCount > 0 {
            entries.append(.smallFiles(
                count: smallFileCount,
                bytes: ownFileBytes - largeFiles.reduce(0) { $0 + $1.allocatedBytes },
                unsharedBytes: ownUnsharedBytes - largeFiles.reduce(0) { $0 + $1.unsharedBytes }
            ))
        }
        return entries.sorted { $0.bytes > $1.bytes }
    }

    /// 하위 디렉터리를 트리에서 떼어 내고 이 노드와 조상의 합계에서 그만큼 뺀다.
    /// 항목을 지운 뒤 다시 스캔하지 않고 화면을 고칠 때 쓴다.
    public func removeChild(_ child: DirectoryNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        subtractFromTotals(
            bytes: child.totalBytes,
            unsharedBytes: child.totalUnsharedBytes,
            files: child.totalFileCount,
            directories: child.totalDirectoryCount + 1
        )
    }

    /// 이름을 남긴 큰 파일 하나를 떼어 내고 합계에서 뺀다.
    public func removeLargeFile(named name: String) {
        guard let index = largeFiles.firstIndex(where: { $0.name == name }) else { return }
        let file = largeFiles.remove(at: index)
        ownFileBytes -= file.allocatedBytes
        ownUnsharedBytes -= file.unsharedBytes
        ownFileCount -= 1
        subtractFromTotals(bytes: file.allocatedBytes, unsharedBytes: file.unsharedBytes, files: 1, directories: 0)
    }

    private func subtractFromTotals(bytes: Int64, unsharedBytes: Int64, files: Int, directories: Int) {
        var node: DirectoryNode? = self
        while let current = node {
            current.totalBytes -= bytes
            current.totalUnsharedBytes -= unsharedBytes
            current.totalFileCount -= files
            current.totalDirectoryCount -= directories
            node = current.parent
        }
    }

    /// 하위 노드의 합계를 아래에서 위로 채운다. 깊은 트리에서도 스택이 넘치지 않도록 재귀 대신 반복으로 돈다.
    func aggregateTotals() {
        var preorder: [DirectoryNode] = []
        var stack = [self]
        while let node = stack.popLast() {
            preorder.append(node)
            stack.append(contentsOf: node.children)
        }
        for node in preorder.reversed() {
            var bytes = node.ownFileBytes
            var unsharedBytes = node.ownUnsharedBytes
            var files = node.ownFileCount
            var directories = 0
            for child in node.children {
                bytes += child.totalBytes
                unsharedBytes += child.totalUnsharedBytes
                files += child.totalFileCount
                directories += child.totalDirectoryCount + 1
            }
            node.totalBytes = bytes
            node.totalUnsharedBytes = unsharedBytes
            node.totalFileCount = files
            node.totalDirectoryCount = directories
        }
    }
}

public struct FileEntry: Sendable, Hashable {
    public let name: String
    public let allocatedBytes: Int64
    public let unsharedBytes: Int64
}

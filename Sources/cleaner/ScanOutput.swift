import CleanerCore
import Foundation

/// 하위 디렉터리, 큰 파일, 나머지 작은 파일을 크기순으로 섞어 보여준다.
func printChildren(of node: DirectoryNode, depth: Int, top: Int, indent: String) {
    let entries = node.entries
    for entry in entries.prefix(top) {
        let bytes = entry.bytes
        switch entry {
        case .directory(let child):
            let note = switch child.status {
            case .scanned: ""
            case .otherVolume: "  [다른 볼륨, 건너뜀]"
            case .excluded: "  [제외]"
            case .cloudOnly: "  [클라우드 전용]"
            case .unreadable(let code): "  [읽기 실패: \(errorDescription(code))]"
            }
            print(sizeLine(indent: indent, bytes, child.name + "/" + note, unsharedBytes: child.totalUnsharedBytes))
            if depth > 1, child.status == .scanned {
                printChildren(of: child, depth: depth - 1, top: top, indent: indent + "    ")
            }
        case .file(let file):
            print(sizeLine(indent: indent, bytes, file.name, unsharedBytes: file.unsharedBytes))
        case .smallFiles(let count, _, _):
            print(sizeLine(indent: indent, bytes, "(작은 파일 \(count.formatted())개)"))
        }
    }
    if entries.count > top {
        let rest = entries.dropFirst(top)
        print(sizeLine(indent: indent, rest.reduce(0) { $0 + $1.bytes }, "… 외 \(rest.count.formatted())개"))
    }
}

func paths(in root: DirectoryNode, with status: DirectoryNode.Status) -> [String] {
    var paths: [String] = []
    var stack = [root]
    while let node = stack.popLast() {
        if node.status == status { paths.append(node.path) }
        stack.append(contentsOf: node.children)
    }
    return paths.sorted()
}

func printScanReport(_ result: ScanResult, threads: Int, depth: Int, top: Int) {
    let root = result.root
    print("\(root.name)  \(formatBytes(root.totalBytes))")
    printChildren(of: root, depth: depth, top: top, indent: "  ")

    print("")
    print("합계        \(root.totalBytes.formatted()) 바이트 (\(formatBytes(root.totalBytes)))")
    print("클론 공유 제외 \(formatBytes(root.totalUnsharedBytes)) — 지우면 확실히 비워지는 최소치")
    print("항목        디렉터리 \(root.totalDirectoryCount.formatted())개 · 파일 \(root.totalFileCount.formatted())개")
    print("소요 시간   \(formatSeconds(result.duration))초 (스레드 \(threads)개, 최대 메모리 \(formatBytes(peakMemoryBytes())))")
    if result.skippedHardLinkBytes > 0 {
        print("하드링크    중복 \(formatBytes(result.skippedHardLinkBytes))는 한 번만 셈")
    }

    let volumes = paths(in: root, with: .otherVolume)
    if !volumes.isEmpty {
        print("다른 볼륨   \(volumes.count)곳 건너뜀")
        for path in volumes.prefix(5) { print("            \(path)") }
    }

    let cloudOnly = paths(in: root, with: .cloudOnly)
    if !cloudOnly.isEmpty {
        print("클라우드 전용 \(cloudOnly.count)곳 — 내려받지 않은 폴더라 크기에서 빠짐")
        for path in cloudOnly.prefix(5) { print("            \(path)") }
    }

    if !result.issues.isEmpty {
        let counts = Dictionary(grouping: result.issues, by: \.errno)
            .map { "\(errorDescription($0.key)) \($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
        print("읽지 못함   \(result.issues.count)곳 (\(counts))")
        for issue in result.issues.prefix(5) { print("            \(issue.path)") }
    }
}

import CleanerCore
import Darwin
import Foundation

func writeError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatSeconds(_ duration: Duration) -> String {
    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    return String(format: "%.2f", seconds)
}

func errorDescription(_ code: Int32) -> String {
    String(cString: strerror(code))
}

func describe(_ error: any Error) -> String {
    switch error {
    case ScanError.cannotAccess(let path, let code): "\(path): \(errorDescription(code))"
    case ScanError.notADirectory(let path): "\(path): 디렉터리가 아닙니다"
    default: "\(error)"
    }
}

/// 홈 디렉터리를 `~`로 줄인다. 데이터 볼륨을 스캔했을 때 붙는 접두어도 뗀다.
func abbreviate(_ path: String) -> String {
    var path = path
    let dataVolume = "/System/Volumes/Data"
    if path.hasPrefix(dataVolume + "/") {
        path.removeFirst(dataVolume.count)
    }
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

/// 터미널에서 차지하는 칸 수. 한글과 한자는 두 칸을 차지한다.
func displayWidth(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { width, scalar in
        switch scalar.value {
        case 0x0300...0x036F, 0x1160...0x11FF: width  // 결합 문자, 한글 중성·종성 자모(NFD)
        case 0x1100...0x115F, 0x2E80...0x9FFF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFF00...0xFF60: width + 2
        default: width + 1
        }
    }
}

/// 크기를 오른쪽 정렬한 한 줄. 클론과 공유하는 블록이 10% 넘게 섞여 있으면 확실히 비워지는 크기를 함께 적는다.
func sizeLine(indent: String, _ bytes: Int64, _ label: String, unsharedBytes: Int64? = nil) -> String {
    let size = formatBytes(bytes)
    var text = indent + String(repeating: " ", count: max(0, 10 - size.count)) + size + "  " + label
    if let unsharedBytes, unsharedBytes * 10 < bytes * 9 {
        text += "  (클론 공유 제외 \(formatBytes(unsharedBytes)))"
    }
    return text
}

/// 터미널이면 스캔 진행 상황을 한 줄로 덮어쓰며 보여준다.
func reportProgress(_ progress: ScanProgress) async {
    while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(200))
        let line = "스캔 중… 디렉터리 \(progress.directories.formatted())개 · "
            + "파일 \(progress.files.formatted())개 · \(formatBytes(progress.bytes))"
        writeError("\r\u{1B}[K" + line)
    }
}

/// 진행 상황 줄을 지운다. 터미널이 아니면 아무것도 하지 않는다.
func clearProgressLine() {
    if isatty(STDERR_FILENO) == 1 {
        writeError("\r\u{1B}[K")
    }
}

func peakMemoryBytes() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}

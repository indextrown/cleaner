import Foundation

/// git이 추적하는 파일이 든 후보를 `.review` 등급으로 내린다.
///
/// 이름과 마커가 맞아도 커밋된 디렉터리(라이브러리가 함께 배포하는 `dist`, 빌드 리소스를 담은 `build` 등)는
/// 소스일 수 있다. 다만 실수로 산출물 일부를 커밋한 경우(`.build/index-build` 등)도 흔해서, 후보에서 빼지 않고
/// 사람이 판단하도록 남긴다. 저장소마다 `git ls-files`를 한 번만 부른다.
public struct GitTrackedFilter: Sendable {
    public var gitExecutable: String

    public init(gitExecutable: String = "/usr/bin/git") {
        self.gitExecutable = gitExecutable
    }

    /// git을 실행하지 못한 저장소의 후보는 그대로 둔다.
    public func apply(to report: CleanupReport) async -> CleanupReport {
        var indicesByRepository: [String: [Int]] = [:]
        for (index, candidate) in report.candidates.enumerated() {
            if case .project(let root, isGitRepository: true) = candidate.group {
                indicesByRepository[root, default: []].append(index)
            }
        }

        var candidates = report.candidates
        for (repository, indices) in indicesByRepository {
            let relativePaths = indices.map { String(candidates[$0].path.dropFirst(repository.count + 1)) }
            guard let trackedFiles = await trackedFiles(in: repository, under: relativePaths) else { continue }
            for (index, relativePath) in zip(indices, relativePaths) {
                // git은 NFC로, 디스크 이름은 NFD로 나올 수 있다. String 비교는 정규화가 달라도 같다고 본다.
                let prefix = relativePath + "/"
                let count = trackedFiles.count { $0.hasPrefix(prefix) }
                if count > 0 {
                    candidates[index].trackedFileCount = count
                    candidates[index].grade = .review
                }
            }
        }
        return CleanupReport(candidates: candidates, rejected: report.rejected)
    }

    /// `paths` 아래에서 git이 추적하는 파일의 저장소 기준 경로. git이 실패하면 nil.
    private func trackedFiles(in repository: String, under paths: [String]) async -> [String]? {
        let executable = gitExecutable
        // Process는 블로킹이라 협력 스레드 풀 밖에서 돌린다.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runListFiles(executable, repository: repository, paths: paths))
            }
        }
    }

    private static func runListFiles(_ executable: String, repository: String, paths: [String]) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", repository, "ls-files", "-z", "--"] + paths
        var environment = ProcessInfo.processInfo.environment
        // 경로를 와일드카드가 아닌 글자 그대로 해석하고, 인덱스 잠금을 잡지 않는다.
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
}

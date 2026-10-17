import CleanerCore
import Foundation

let usage = """
    사용법:
      cleaner scan <경로> [--threads N] [--depth N] [--top N]
      cleaner candidates <경로> [--project <폴더>]... [--threads N] [--top N] [--tsv]
      cleaner clean <경로> [--project <폴더>]... [--grade 등급]... [--rule ID]... [--under <폴더>]...
                    [--exclude <경로>]... [--runtime 버전]... [--trash] [--yes]
      cleaner apps [--sort name|size|unshared|added|used] [--asc|--desc] [--top N]
      cleaner uninstall <앱 이름|번들 ID|경로>... [--leftovers] [--yes]

    scan        <경로>를 스캔해 큰 폴더를 크기순 트리로 보여준다.
    candidates  <경로>를 스캔해 빌드 산출물·캐시 후보를 등급별로 보여준다. node_modules 같은 프로젝트
                규칙은 --project로 준 폴더 안에서만 찾고, --project가 없으면 <경로>를 프로젝트 폴더로 본다.
    clean       candidates로 찾은 후보 중 고른 것을 지운다. --yes가 없으면 미리보기만 하고 아무것도 지우지 않는다.
    apps        /Applications와 ~/Applications의 앱을 정렬해 보여준다. 기본은 크기 내림차순.
    uninstall   앱을 휴지통으로 옮긴다. ~/Library에 남은 데이터도 찾아 보여주고, --leftovers를 주면
                번들 ID로 찾은 데이터도 함께 옮긴다. --yes가 없으면 미리보기만 한다.

      --threads N      디렉터리를 동시에 읽을 스레드 수 (기본: \(ScanOptions.defaultThreadCount))
      --depth N        scan: 출력할 트리 깊이 (기본: 2)
      --top N          단계·묶음마다 보여줄 항목 수 (기본: 10)
      --project 폴더   candidates, clean: 프로젝트 폴더. 여러 번 줄 수 있다
      --tsv            candidates: 탭으로 구분한 목록을 출력한다
      --grade 등급     clean: artifact(빌드 산출물), cache(캐시), review(판단 필요). 기본: artifact, cache
      --rule ID        clean: 이 규칙의 후보만 고른다 (예: npm.nodeModules)
      --under 폴더     clean: 이 폴더 아래의 후보만 고른다
      --exclude 경로   clean: 이 경로와 그 아래의 후보는 고르지 않는다 (실행 중인 앱의 캐시를 뺄 때 등)
      --runtime 버전   clean: 이 버전의 시뮬레이터 런타임만 고른다 (예: 18.2). 주면 다른 후보는 고르지 않는다
      --trash          clean: 바로 지우지 않고 휴지통으로 옮긴다. 휴지통을 비워야 공간이 생긴다
      --yes            clean, uninstall: 미리보기에 나온 대로 실제로 실행한다
      --sort 기준      apps: name(이름), size(크기 최대), unshared(크기 최소), added(추가된 날짜), used(마지막 사용)
      --asc, --desc    apps: 오름차순, 내림차순
      --leftovers      uninstall: 번들 ID로 찾은 남은 데이터도 함께 휴지통으로 옮긴다

    디스크 전체를 보려면 데이터 볼륨을 지정한다: cleaner scan /System/Volumes/Data
    """

struct Arguments {
    enum Command: String {
        case scan
        case candidates
        case clean
        case apps
        case uninstall
    }

    var command: Command
    /// 명령 뒤의 위치 인자. scan·candidates·clean은 경로 하나, uninstall은 앱 하나 이상, apps는 없음.
    var positionals: [String] = []
    var threads = ScanOptions.defaultThreadCount
    var depth = 2
    /// 주지 않으면 명령마다 기본값을 쓴다(apps는 전부, 나머지는 10).
    var top: Int?
    var projects: [String] = []
    var tsv = false
    var grades: Set<CleanupGrade> = []
    var rules: Set<String> = []
    var under: [String] = []
    var excluded: [String] = []
    var trash = false
    var yes = false
    var runtimes: Set<String> = []
    var sortKey = ApplicationSortKey.size
    var sortOrder: SortOrder = .reverse
    var leftovers = false

    var path: String { positionals[0] }

    init?(_ arguments: [String]) {
        guard let first = arguments.first, let command = Command(rawValue: first) else { return nil }
        self.command = command
        var remaining = arguments.dropFirst()
        while let argument = remaining.popFirst() {
            switch argument {
            case "--threads", "--depth", "--top":
                guard let value = remaining.popFirst().flatMap({ Int($0) }), value > 0 else { return nil }
                switch argument {
                case "--threads": threads = value
                case "--depth": depth = value
                default: top = value
                }
            case "--sort":
                switch remaining.popFirst() {
                case "name": sortKey = .name
                case "size": sortKey = .size
                case "unshared": sortKey = .unsharedSize
                case "added": sortKey = .added
                case "used": sortKey = .lastUsed
                default: return nil
                }
            case "--asc":
                sortOrder = .forward
            case "--desc":
                sortOrder = .reverse
            case "--leftovers":
                leftovers = true
            case "--project", "--rule", "--under", "--exclude", "--runtime":
                guard let value = remaining.popFirst() else { return nil }
                switch argument {
                case "--project": projects.append(value)
                case "--rule": rules.insert(value)
                case "--runtime": runtimes.insert(value)
                case "--exclude": excluded.append(value)
                default: under.append(value)
                }
            case "--grade":
                switch remaining.popFirst() {
                case "artifact": grades.insert(.buildArtifact)
                case "cache": grades.insert(.cache)
                case "review": grades.insert(.review)
                default: return nil
                }
            case "--tsv":
                tsv = true
            case "--trash":
                trash = true
            case "--yes":
                yes = true
            default:
                guard !argument.hasPrefix("-") else { return nil }
                positionals.append(argument)
            }
        }
        switch command {
        case .scan, .candidates, .clean:
            guard positionals.count == 1 else { return nil }
        case .apps:
            guard positionals.isEmpty else { return nil }
        case .uninstall:
            guard !positionals.isEmpty else { return nil }
        }
    }
}

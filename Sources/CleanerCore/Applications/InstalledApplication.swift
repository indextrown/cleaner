import Foundation

/// 설치된 앱 하나.
public struct InstalledApplication: Sendable, Identifiable {
    public let path: String
    /// Finder에 보이는 이름(현지화된 이름).
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?
    public let identity: FileIdentity
    /// 앱 번들의 할당 크기. 지웠을 때 비워질 수 있는 최대치다.
    public let allocatedBytes: Int64
    /// 클론과 공유하지 않는 크기. 지웠을 때 확실히 비워지는 최소치다.
    public let unsharedBytes: Int64
    /// Finder의 "추가된 날짜". 앱이 이 폴더에 들어온 시각이라, 마이그레이션으로 옮긴 앱은 옮긴 날로 나온다.
    public let addedDate: Date?
    /// Spotlight가 기록한 마지막 실행 시각. 기록이 없으면 nil.
    public let lastUsedDate: Date?
    public let isFromAppStore: Bool

    public var id: String { path }
}

public enum ApplicationSortKey: String, Sendable, CaseIterable {
    case name
    /// 할당 크기(최대치)
    case size
    /// 클론 공유 제외 크기(최소치)
    case unsharedSize
    /// 추가된 날짜(설치일)
    case added
    /// 마지막 사용일
    case lastUsed
}

/// 앱 정렬 기준. SwiftUI `Table`의 열 정렬에 그대로 쓸 수 있다.
///
/// `.forward`가 오름차순, `.reverse`가 내림차순이다. 날짜가 없는 앱은 순서와 상관없이 맨 뒤에 두고,
/// 값이 같으면 이름 오름차순으로 둔다.
public struct ApplicationComparator: SortComparator, Sendable, Hashable {
    public var key: ApplicationSortKey
    public var order: SortOrder

    public init(_ key: ApplicationSortKey, order: SortOrder = .forward) {
        self.key = key
        self.order = order
    }

    public func compare(_ lhs: InstalledApplication, _ rhs: InstalledApplication) -> ComparisonResult {
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        let comparison: ComparisonResult
        switch key {
        case .name:
            comparison = byName
        case .size:
            comparison = Self.compare(lhs.allocatedBytes, rhs.allocatedBytes)
        case .unsharedSize:
            comparison = Self.compare(lhs.unsharedBytes, rhs.unsharedBytes)
        case .added, .lastUsed:
            let left = key == .added ? lhs.addedDate : lhs.lastUsedDate
            let right = key == .added ? rhs.addedDate : rhs.lastUsedDate
            switch (left, right) {
            case let (left?, right?):
                comparison = Self.compare(left, right)
            case (nil, nil):
                comparison = .orderedSame
            case (nil, _):
                return .orderedDescending
            case (_, nil):
                return .orderedAscending
            }
        }
        if comparison == .orderedSame {
            return key == .name ? .orderedSame : byName
        }
        guard order == .reverse else { return comparison }
        return comparison == .orderedAscending ? .orderedDescending : .orderedAscending
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }
}

extension Sequence<InstalledApplication> {
    /// `ApplicationComparator`로 정렬한다.
    public func sorted(by key: ApplicationSortKey, _ order: SortOrder) -> [InstalledApplication] {
        sorted(using: ApplicationComparator(key, order: order))
    }
}

import Foundation

enum DiscoveryScanScope: Equatable {
    case none
    case sources(Set<String>)
    case all

    mutating func merge(_ sources: Set<String>?) {
        switch (self, sources) {
        case (_, nil):
            self = .all
        case (.all, _):
            return
        case (.none, .some(let sources)):
            self = .sources(sources)
        case (.sources(let existing), .some(let sources)):
            self = .sources(existing.union(sources))
        }
    }
}

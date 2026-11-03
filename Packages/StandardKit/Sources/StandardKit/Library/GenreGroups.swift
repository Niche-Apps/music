import Foundation

/// Folds the writer's very specific genres ("piano-driven pop rock", "portuguese acoustic folk-pop")
/// into the handful of shelves a person would actually browse.
public enum GenreGroups {
    /// Words that say where an act is from rather than what it sounds like.
    static let placeWords: Set<String> = [
        "portuguese", "french", "française", "francophone", "italian", "spanish", "spanish-language", "norwegian",
        "swedish", "danish", "finnish", "german", "dutch", "argentine", "brazilian", "mexican", "japanese", "korean",
        "british", "american", "australian", "canadian", "irish", "scottish", "icelandic",
    ]

    /// Maps each raw genre (lowercased) to the display name of its group, given album counts.
    public static func make(_ counts: [String: Int]) -> [String: String] {
        // 1. Merge genres that differ only by place or by how they phrase an instrument.
        var canonicalOf: [String: String] = [:]
        var groups: [String: (count: Int, members: [String: Int])] = [:]
        for (raw, n) in counts {
            let key = raw.lowercased()
            let canonical = canonicalName(key)
            canonicalOf[key] = canonical
            groups[canonical, default: (0, [:])].count += n
            groups[canonical]!.members[key, default: 0] += n
        }

        // 2. Fold each group into a bigger one whose words contain, or are contained by, its own
        //    ("piano pop rock" into "piano rock"); tiny groups join their closest neighbor.
        var target: [String: String] = [:]
        for name in groups.keys.sorted(by: { (groups[$0]!.count, $1) < (groups[$1]!.count, $0) }) {
            let own = words(name), count = groups[name]!.count
            let larger = groups.keys.filter { $0 != name && groups[$0]!.count >= count && target[$0] == nil }
            let related = larger.filter { let w = words($0); return w.isSubset(of: own) || own.isSubset(of: w) }
            if let into = related.max(by: { groups[$0]!.count < groups[$1]!.count }) {
                target[name] = into
            } else if count < 3,
                let into = larger.map({ ($0, words($0).intersection(own).count) }).filter({ $0.1 > 0 })
                    .max(by: { ($0.1, groups[$0.0]!.count) < ($1.1, groups[$1.0]!.count) })?.0
            {
                target[name] = into
            }
        }
        func root(_ name: String) -> String {
            var n = name
            while let next = target[n] { n = next }
            return n
        }

        // Each group is named after its most common original spelling.
        var display: [String: String] = [:]
        var rootMembers: [String: [String: Int]] = [:]
        for (canonical, group) in groups { rootMembers[root(canonical), default: [:]].merge(group.members, uniquingKeysWith: +) }
        for (r, members) in rootMembers {
            let lead = members.filter { canonicalName($0.key) == r }.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? r
            display[r] = lead.capitalized
        }
        return canonicalOf.mapValues { display[root($0)]! }
    }

    static func canonicalName(_ genre: String) -> String {
        let name = genre.lowercased()
            .replacingOccurrences(of: "-driven", with: "")
            .replacingOccurrences(of: "-led", with: "")
            .split(separator: " ").map(String.init)
            .filter { !placeWords.contains($0) }
            .joined(separator: " ")
        return name.isEmpty ? genre.lowercased() : name
    }

    static func words(_ genre: String) -> Set<String> {
        Set(genre.split { $0 == " " || $0 == "-" }.map(String.init))
    }
}

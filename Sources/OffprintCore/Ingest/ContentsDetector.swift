import Foundation

/// Recognises a table of contents.
///
/// A contents page is structurally two columns — title on the left, page number
/// on the right — so a table detector classifies it as a table, and then cannot
/// verify it, which is why a document with a long contents section produces a
/// run of "structure uncertain" warnings and no usable outline. It is not a
/// table: it is a nested list of pointers, and saying so gives both a readable
/// rendering and something a downstream model can navigate by.
public enum ContentsDetector {

    public struct Detected: Sendable {
        public var lineIndices: Range<Int>
        public var list: Block.List
        public var bbox: BoundingBox
    }

    public struct Entry: Sendable, Equatable {
        public var title: String
        public var page: String
        public var depth: Int
    }

    /// Consecutive contents entries needed before a run counts.
    public static let minimumEntries = 3

    public static func detect(in lines: [TextLayerGeometry.Line]) -> [Detected] {
        var out: [Detected] = []
        var index = 0

        while index < lines.count {
            guard entry(from: lines[index].text) != nil else { index += 1; continue }

            var end = index
            var entries: [Entry] = []
            while end < lines.count, let parsed = entry(from: lines[end].text) {
                // A contents section does not jump between page columns.
                if end > index, lines[end].column != lines[end - 1].column { break }
                entries.append(parsed)
                end += 1
            }

            if entries.count >= minimumEntries {
                let range = index..<end
                let bbox = range.dropFirst().reduce(lines[index].bbox) { $0.union(lines[$1].bbox) }
                // Depth comes from the section number itself rather than from
                // where this run happens to start, so a contents section split
                // across a page break keeps a consistent indent on both sides.
                let items = entries.map {
                    Block.List.Item(text: "\($0.title) · p. \($0.page)",
                                    depth: max(0, $0.depth - 1))
                }
                out.append(Detected(lineIndices: range,
                                    list: .init(ordered: false, items: items, bbox: bbox),
                                    bbox: bbox))
                index = end
            } else {
                index = max(end, index + 1)
            }
        }
        return out
    }

    /// Parses one contents line: a title, optional dot leaders, a page number.
    public static func entry(from text: String) -> Entry? {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard line.count >= 5 else { return nil }

        // The page reference is the trailing number — arabic, or roman for front
        // matter, which is common in official documents.
        var tail = ""
        var index = line.endIndex
        while index > line.startIndex {
            let previous = line.index(before: index)
            let character = line[previous]
            guard character.isNumber || Self.romanNumerals.contains(character) else { break }
            tail.insert(character, at: tail.startIndex)
            index = previous
        }
        guard !tail.isEmpty, tail.count <= 6 else { return nil }
        // A roman page number must be entirely roman, not a title ending in "I".
        if tail.contains(where: { !$0.isNumber }) && tail.contains(where: \.isNumber) { return nil }

        let beforeNumber = String(line[line.startIndex..<index])
        // A run of dots, or the wide whitespace that stands in for one. A single
        // space is not evidence: "the figure rose to 2019" would qualify, and a
        // sentence ending in a year is the commonest false positive here.
        let trailing = beforeNumber.reversed().prefix { $0 == "." || $0 == "·" || $0 == "…"
            || $0 == " " || $0 == "\u{00A0}" || $0 == "\t" }
        let dots = trailing.filter { $0 == "." || $0 == "·" || $0 == "…" }.count
        let hadLeader = dots >= 2 || trailing.count >= 3

        let title = beforeNumber
            .trimmingCharacters(in: CharacterSet(charactersIn: " .·…\u{00A0}\t-–—"))
        guard title.count >= 3, title.contains(where: \.isLetter) else { return nil }
        // A numbered heading is a contents entry even when the leader was lost
        // in extraction; anything else has to show one.
        let numbered = HeadingHeuristic.sectionDepth(of: title) != nil
        guard hadLeader || numbered else { return nil }

        // Reject prose that merely ends in a number: a contents entry is a
        // label, not a sentence.
        guard !title.hasSuffix(",") else { return nil }

        let depth = HeadingHeuristic.sectionDepth(of: title) ?? 1
        return Entry(title: title, page: tail, depth: depth)
    }

    static let romanNumerals: Set<Character> = ["i", "v", "x", "l", "c", "d", "m",
                                                "I", "V", "X", "L", "C", "D", "M"]
}

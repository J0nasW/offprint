import Foundation

/// Tidies blocks after extraction, independently of which engine produced them.
public enum BlockNormalizer {

    /// Characters that stand in for a list bullet.
    static let bullets: Set<Character> = ["•", "●", "▪", "◦", "‣", "·", "-", "–", "—", "*", "o", "□", "❑"]

    public static func normalize(_ blocks: [Block]) -> [Block] {
        blocks.map { block in
            guard case .table(let original) = block else { return block }
            if let list = listFromBulletColumn(original) { return .list(list) }
            var table = original
            table.structureSuspect = table.structureSuspect && isDoubtful(table)
            return .table(table)
        }
    }

    /// A two-column table whose first column holds only bullets is a list.
    ///
    /// Both engines produce this shape: a bulleted list sets its markers in a
    /// consistent column, which is exactly what column detection looks for. It
    /// renders as a table with a column of dots, which is worse than useless.
    static func listFromBulletColumn(_ table: Block.Table) -> Block.List? {
        guard table.rows.count >= 2 else { return nil }
        let widths = Set(table.rows.map(\.count))
        guard widths == [2] else { return nil }

        var sawBullet = false
        for row in table.rows {
            let marker = row[0].text.trimmingCharacters(in: .whitespaces)
            if marker.isEmpty { continue }          // a wrapped continuation line
            guard marker.count <= 2, marker.allSatisfy({ bullets.contains($0) }) else { return nil }
            sawBullet = true
        }
        guard sawBullet else { return nil }

        var items: [Block.List.Item] = []
        for row in table.rows {
            let text = row[1].text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let marker = row[0].text.trimmingCharacters(in: .whitespaces)
            if marker.isEmpty, var last = items.popLast() {
                // An empty marker means this row continues the previous item.
                last.text += " " + text
                items.append(last)
            } else {
                items.append(.init(text: text))
            }
        }
        guard !items.isEmpty else { return nil }
        return .init(ordered: false, items: items, bbox: table.bbox)
    }

    /// Whether a table looks mis-split, rather than merely unverified.
    ///
    /// The flag has to be earned. Marking every geometrically-derived table
    /// uncertain trains the reader to ignore the warning, which costs more than
    /// it saves — the point of the flag is that a wrongly-split table still
    /// renders as perfectly valid Markdown.
    static func isDoubtful(_ table: Block.Table) -> Bool {
        let cells = table.rows.flatMap { $0 }
        guard !cells.isEmpty else { return true }

        let filled = cells.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let fillRatio = Double(filled) / Double(cells.count)
        // A grid that is mostly empty means the columns were imagined.
        if fillRatio < 0.55 { return true }

        // Cells holding whole sentences are prose that was cut into columns.
        let wordy = cells.filter { $0.text.split(separator: " ").count > 12 }.count
        if Double(wordy) / Double(cells.count) > 0.3 { return true }

        return false
    }
}

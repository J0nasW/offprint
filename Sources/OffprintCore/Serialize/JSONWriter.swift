import Foundation

/// Serialises a document to the stable Offprint JSON schema.
///
/// Deliberately *not* Apple's `DocumentObservation` encoding: that would leak
/// framework internals into a public file format and break whenever the OS
/// changes its private representation.
public struct JSONWriter: Sendable {
    public struct Options: Sendable {
        public var prettyPrinted: Bool
        public init(prettyPrinted: Bool = true) { self.prettyPrinted = prettyPrinted }
    }

    public var options: Options
    public init(options: Options = .init()) { self.options = options }

    public func data(for document: OffprintDocument) throws -> Data {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if options.prettyPrinted { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        return try encoder.encode(document)
    }

    public func string(for document: OffprintDocument) throws -> String {
        String(decoding: try data(for: document), as: UTF8.self)
    }

    public static func decode(_ data: Data) throws -> OffprintDocument {
        try JSONDecoder().decode(OffprintDocument.self, from: data)
    }
}

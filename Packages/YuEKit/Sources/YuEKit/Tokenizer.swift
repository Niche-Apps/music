import Foundation

/// The frozen Qwen byte-level BPE used by YuE2 for text and ABC (tiktoken rank-file format).
public final class Tokenizer: Sendable {
    private let ranks: [Data: Int]
    private let decoder: [Int: Data]
    private let pattern: NSRegularExpression

    public init(rankFile: URL) throws {
        let contents = try String(contentsOf: rankFile, encoding: .utf8)
        var ranks = [Data: Int](minimumCapacity: 152_000)
        var decoder = [Int: Data](minimumCapacity: 152_000)
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let bytes = Data(base64Encoded: String(parts[0])),
                let rank = Int(parts[1])
            else { continue }
            ranks[bytes] = rank
            decoder[rank] = bytes
        }
        self.ranks = ranks
        self.decoder = decoder
        self.pattern = try NSRegularExpression(
            pattern:
                #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
        )
    }

    public var vocabularySize: Int { ranks.count }

    /// Equivalent to tiktoken `encode_ordinary` on NFC-normalized text.
    public func encode(_ text: String) -> [Int] {
        let text = text.precomposedStringWithCanonicalMapping
        let ns = text as NSString
        var out: [Int] = []
        out.reserveCapacity(ns.length / 3)
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let piece = Data(ns.substring(with: match.range).utf8)
            if let rank = ranks[piece] {
                out.append(rank)
            } else {
                out.append(contentsOf: bytePairEncode(piece))
            }
        }
        return out
    }

    public func decode(_ ids: [Int]) -> String {
        var bytes = Data()
        for id in ids { if let piece = decoder[id] { bytes.append(piece) } }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func bytePairEncode(_ piece: Data) -> [Int] {
        var parts = piece.map { Data([$0]) }
        while parts.count > 1 {
            var best: (index: Int, rank: Int)?
            for i in 0 ..< parts.count - 1 {
                if let rank = ranks[parts[i] + parts[i + 1]], rank < (best?.rank ?? .max) {
                    best = (i, rank)
                }
            }
            guard let best else { break }
            parts[best.index] += parts[best.index + 1]
            parts.remove(at: best.index + 1)
        }
        return parts.compactMap { ranks[$0] }
    }
}

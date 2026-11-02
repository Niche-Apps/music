import AppKit
import GRDB
import StandardKit
import SwiftUI

extension Color {
    /// `#RRGGBB` → Color. Returns nil for malformed input.
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            .sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }

    static let brand = Color.accentColor
}

enum Metrics {
    static let artworkCorner: CGFloat = 6
    static let largeArtworkCorner: CGFloat = 10
    static let cardWidth: CGFloat = 176
    static let pagePadding: CGFloat = 32
}

enum Format {
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–:––" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "About 4 min" style estimate.
    static func remaining(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        if seconds < 50 { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        return "About \(minutes) min left"
    }

    static func totalDuration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 { return "\(minutes / 60) hr \(minutes % 60) min" }
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}

// MARK: - Live database queries

extension View {
    /// Observes a database value and calls `update` on the main actor whenever it changes.
    /// Pass `immediate: false` for heavy queries so the first fetch doesn't block the main thread.
    func observing<Value: Sendable & Equatable>(
        _ db: AppDatabase, id: some Equatable = 0, immediate: Bool = true,
        _ fetch: @escaping @Sendable (Database) throws -> Value,
        update: @escaping @MainActor (Value) -> Void
    ) -> some View {
        task(id: id) {
            let observation = ValueObservation.tracking(fetch).removeDuplicates()
            do {
                if immediate {
                    for try await value in observation.values(in: db.reader, scheduling: .immediate) { update(value) }
                } else {
                    for try await value in observation.values(in: db.reader) { update(value) }
                }
            } catch {}
        }
    }
}

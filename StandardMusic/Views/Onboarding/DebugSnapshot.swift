import AppKit
import StandardKit
import SwiftUI

#if DEBUG

extension View {
    /// Development aid: with `SM_SNAPSHOT=<dir>` set, writes PNGs of the key window every few seconds
    /// (works without screen-recording permission, e.g. over SSH).
    func debugSnapshots(_ name: String) -> some View {
        task {
            guard let dir = ProcessInfo.processInfo.environment["SM_SNAPSHOT"] else { return }
            for i in 1 ... 30 {
                try? await Task.sleep(for: .seconds(4))
                guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 })?
                    .contentView?.superview,
                    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(i).png"))
            }
        }
    }
}

extension OnboardingFlow {
    /// Development aid: with `SM_ONBOARDING_AUTOPILOT` set, clicks through onboarding so snapshots can
    /// show every step. Refines the profile directly instead of finishing (no library build starts).
    func autopilot() async {
        guard ProcessInfo.processInfo.environment["SM_ONBOARDING_AUTOPILOT"] != nil else { return }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        await wait(3)
        for g in genres.prefix(4) where [0, 2, 3].contains(genres.firstIndex(of: g)!) { toggle(genre: g.name) }
        await wait(3)
        advance()
        await wait(4)
        for a in cloud.prefix(5) where cloud.firstIndex(of: a)! % 2 == 0 { toggle(artist: a) }
        await wait(4)
        advance()
        for i in 0 ..< Self.questionCount {
            while questions[i] == nil { await wait(1) }
            await wait(4.5)
            let q = questions[i]!
            let artists = (try? catalog?.artists(ids: q.artistIDs)) ?? []
            record(.init(answer: TasteAnswer(question: q.title, answer: "Autopilot"), liked: Array(artists.prefix(1))), for: i)
        }
        await wait(1)
        notes = "More female vocals. Nothing too heavy."
        await wait(3)
        advance()
        if ProcessInfo.processInfo.environment["SM_ONBOARDING_AUTOPILOT"] == "full" {
            // finish(using:) runs for real; continue into the library build once the reveal shows.
            while refined == nil { await wait(1) }
            await wait(6)
            autopilotModel?.beginBuilding()
            return
        }
        if let engine, let r = try? await engine.refine(profile()) {
            await wait(4)
            refined = r
            go(to: .reveal)
        }
    }
}
#else
extension View {
    func debugSnapshots(_ name: String) -> some View { self }
}
#endif

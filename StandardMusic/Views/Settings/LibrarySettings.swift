import AppKit
import StandardKit
import SwiftUI

struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var librarySize: Int64?
    @State private var backups: [Date] = []
    @State private var backingUp = false
    @State private var confirmRetake = false
    @State private var confirmErase = false
    @AppStorage(Pref.allowExplicit) private var allowExplicit = false

    private var backupDirectory: URL { Paths.library.appending(path: "Backups", directoryHint: .isDirectory) }

    var body: some View {
        SettingsPane(height: 660) {
            Section("Location") {
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.library]) }
                } label: {
                    Text(Paths.library.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text(librarySize.map { "\($0.formatted(.byteCount(style: .file))) on disk, including recordings and artwork" } ?? "Measuring…")
                }
            }

            Section {
                LabeledContent {
                    HStack {
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([backupDirectory]) }
                            .disabled(backups.isEmpty)
                        Button(backingUp ? "Backing Up…" : "Back Up Now") { Task { await backUp() } }
                            .disabled(backingUp)
                    }
                } label: {
                    Text(backups.first.map { "Last backup \($0.formatted(.relative(presentation: .named)))" } ?? "No backups yet")
                    Text("Your library is backed up automatically and the last seven copies are kept. It’s checked at every launch and restored from a backup if it’s ever damaged.")
                }
            } header: {
                Text("Backups")
            }

            Section("Your taste") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.taste.headline.isEmpty ? "Your taste profile" : model.taste.headline)
                        .font(.headline)
                    if !model.taste.summary.isEmpty {
                        Text(model.taste.summary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.taste.coreGenres.isEmpty {
                        Text(model.taste.coreGenres.prefix(6).joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(.tint)
                    }
                    let favorites = model.taste.signals.count
                    if favorites > 0 {
                        Text("Shaped by your answers and \(favorites) favorite\(favorites == 1 ? "" : "s").")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
                HStack {
                    Spacer()
                    Button("Retake Taste Quiz…") { confirmRetake = true }
                }
                Toggle(isOn: $allowExplicit) {
                    Text("Allow explicit lyrics")
                    Text("A few songs, depending on the genre, may have strong language. They’re marked with an E. Applies to songs written from now on.")
                }
            }

            Section {
                LabeledContent {
                    Button("Erase Library…", role: .destructive) { confirmErase = true }
                } label: {
                    Text("Erase library")
                    Text("Moves every artist, album, recording and playlist to the Trash and starts over.")
                }
            }
        }
        .task { await refresh() }
        .confirmationDialog("Retake the taste quiz?", isPresented: $confirmRetake) {
            Button("Retake Quiz") { retakeQuiz() }
        } message: {
            Text("Your current library stays. New artists will follow your new answers.")
        }
        .confirmationDialog("Erase your entire library?", isPresented: $confirmErase) {
            Button("Erase and Restart", role: .destructive) { eraseLibrary() }
        } message: {
            Text("Standard Music will quit and reopen with an empty library. Your recordings can be recovered from the Trash until you empty it.")
        }
    }

    private func refresh() async {
        librarySize = await DiskUsage.measure(Paths.library).0
        backups = ((try? FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "sqlite" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .sorted(by: >)
    }

    private func backUp() async {
        backingUp = true
        let db = model.services.db
        await Task.detached(priority: .userInitiated) { db.backupIfNeeded(interval: 0) }.value
        await refresh()
        backingUp = false
    }

    private func retakeQuiz() {
        model.onboardingDone = false
        withAnimation(.smooth(duration: 0.6)) { model.phase = .onboarding }
        AppActions.showMainWindow(openWindow: openWindow)
    }

    private func eraseLibrary() {
        model.player.stop()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Pref.eraseLibraryOnLaunch)
        defaults.removeObject(forKey: "averageSecondsPerSong")
        // Relaunch once this process has exited, so the library isn't open while it's moved away.
        var env = ProcessInfo.processInfo.environment
        env["SM_FORCE_PHASE"] = nil
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; exec \"$0\"",
            Bundle.main.executablePath ?? "",
        ]
        relaunch.environment = env
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}

import AppKit
import StandardKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Share

/// "Share Album…": packs the album (or artist) into a .standardalbum file and hands it to
/// AirDrop, Messages, Mail or a folder. Nothing goes through a server.
struct ShareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ShareRequest

    @State private var includeRecordings = true
    @State private var summary: ShareBundler.ExportSummary?
    @State private var file: URL?
    @State private var error: String?
    @State private var outbox = FileManager.default.temporaryDirectory
        .appending(path: "Outbox/\(UUID().uuidString)", directoryHint: .isDirectory)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ArtworkView(
                    source: request.albums.first.map { .album($0) } ?? .artist(request.artist), size: 72,
                    circular: request.albums.isEmpty)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share “\(request.title)”").font(.title3.weight(.semibold)).lineLimit(2)
                    Text(request.albums.isEmpty ? "Every album by this artist" : "by \(request.artist.name)")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Your friend gets the \(request.albums.isEmpty ? "albums" : "album"), the artwork, and everything that makes \(request.artist.name) who they are, so new songs and albums they make on their own Mac stay in character. Your plays and favorites stay private.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let summary {
                VStack(alignment: .leading, spacing: 10) {
                    choice(
                        selected: includeRecordings, title: "Include recordings",
                        detail: summary.recorded == 0
                            ? "Nothing is recorded yet."
                            : "\(summary.recorded) of \(summary.total) songs · \(summary.audioBytes.formatted(.byteCount(style: .file))). "
                                + (summary.recorded == summary.total
                                    ? "They can press play right away."
                                    : "These play right away; the rest record on their Mac.")
                    ) { includeRecordings = true }
                    .disabled(summary.recorded == 0)
                    choice(
                        selected: !includeRecordings, title: "Songs only",
                        detail: "A tiny file. Their Mac records each song the first time they play it."
                    ) { includeRecordings = false }
                }
            } else {
                ProgressView().controlSize(.small)
            }

            HStack(spacing: 10) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                } else if file == nil {
                    ProgressView().controlSize(.small)
                    Text("Packing…").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save As…", action: saveAs).disabled(file == nil)
                if let file {
                    ShareLink(item: file) { Label("Share…", systemImage: "square.and.arrow.up") }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Share…") {}.disabled(true)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .task { await load() }
        .onChange(of: includeRecordings) { _, _ in Task { await pack() } }
        .onDisappear { try? FileManager.default.removeItem(at: outbox) }
    }

    private func choice(selected: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func load() async {
        let sharing = model.services.sharing
        let request = request
        let summary = try? await Task.detached {
            try sharing.summary(artistID: request.artist.id, albumIDs: request.albumIDs)
        }.value
        self.summary = summary
        includeRecordings = (summary?.recorded ?? 0) > 0
        await pack()
    }

    private func pack() async {
        file = nil
        error = nil
        let sharing = model.services.sharing
        let (request, include, outbox) = (request, includeRecordings, outbox)
        let sender = model.shareSenderName
        let engine = model.engineDescription
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try sharing.export(
                    artistID: request.artist.id, albumIDs: request.albumIDs, includeRecordings: include,
                    sharedBy: sender, engine: engine, to: outbox.appending(path: include ? "full" : "songs"))
            }.value
            // The listener may have flipped the choice while this was packing.
            if include == includeRecordings { file = url }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveAs() {
        guard let file else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.allowedContentTypes = [.standardAlbum]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: file, to: target)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Receive

/// Shown when a .standardalbum is opened: what's inside, and "Add to Library".
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    let pending: PendingImport

    private var manifest: ShareManifest { pending.manifest }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ArtworkView(source: .url(pending.artistImage), size: 72, circular: true)
                VStack(alignment: .leading, spacing: 3) {
                    if let name = manifest.sharedBy {
                        Text("\(name) shared").font(.callout).foregroundStyle(.secondary)
                    }
                    Text(manifest.artist.name).font(.title3.weight(.semibold))
                    Text(manifest.artist.tagline.isEmpty ? manifest.artist.primaryGenre : manifest.artist.tagline)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(manifest.albums, id: \.id) { album in
                        HStack(spacing: 10) {
                            ArtworkView(source: .url(pending.cover(album)), size: 44, cornerRadius: 6, shadow: false)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(album.title).lineLimit(1)
                                Text("\(album.kind.label) · \(String(album.releaseYear)) · \(album.tracks.count) songs")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            let recorded = album.tracks.filter { $0.audio != nil }.count
                            Text(recorded == album.tracks.count ? "Recorded" : recorded == 0 ? "To record" : "\(recorded) recorded")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)

            Text(footnote)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { model.cancelImport() }.keyboardShortcut(.cancelAction)
                Button("Add to Library") { model.confirmImport(pending) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var footnote: String {
        let missing = manifest.trackCount - manifest.recordedCount
        if missing == 0 { return "Every song is recorded and ready to play." }
        var text = "\(missing) song\(missing == 1 ? "" : "s") will record on this Mac the first time you play \(missing == 1 ? "it" : "them")."
        if let engine = manifest.engine, engine != model.engineDescription {
            text += missing == 1
                ? " It was made for \(engine), so it may sound a little different here."
                : " They were made for \(engine), so they may sound a little different here."
        }
        return text
    }
}

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations).
    static let standardAlbum = UTType(exportedAs: "com.standardmusic.album", conformingTo: .zip)
}

import AppKit
import AVFoundation
import StandardKit
import SwiftUI
import UniformTypeIdentifiers

/// Keeps the saved picks in step with the library index, file access, and local audio measurements.
enum StyleReferenceRefresh {
    @MainActor
    static func resolve(_ references: [StyleReference], db: AppDatabase) async -> (references: [StyleReference], cues: [StyleCue]) {
        await resolve(references, db: db, progress: { _ in })
    }

    @MainActor
    static func resolve(
        _ references: [StyleReference], db: AppDatabase, progress: @escaping @MainActor (String) -> Void
    ) async -> (references: [StyleReference], cues: [StyleCue]) {
        if Task.isCancelled { return (references, references.compactMap(\.promptCue)) }
        let library = (try? StyleReferenceStore.refreshLibrary(references, in: db)) ?? references
        var resolved: [StyleReference] = []
        for reference in library {
            if Task.isCancelled { return (references, references.compactMap(\.promptCue)) }
            do {
                if reference.cue.kind == .file || reference.cue.kind == .folder {
                    resolved.append(try await LocalStyleFiles.refresh(reference, progress: progress))
                } else {
                    resolved.append(try await LocalStyleFiles.measureLibrary(reference, db: db, progress: progress))
                }
            } catch is CancellationError {
                return (references, references.compactMap(\.promptCue))
            } catch {
                resolved.append(reference)
            }
        }
        return (resolved, resolved.compactMap(\.promptCue))
    }
}

struct VocalOnlyNote: View {
    var body: some View {
        Text("A cappella is sent with the song as style tags (vocals only, no instruments). The studio follows those tags as guidance; it can’t force every model to leave every instrument out. If a reference is instrumental, your request wins.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Album, song, file, or folder picks for a style. Metadata only.
struct StyleReferenceEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var references: [StyleReference]
    @Binding var analysisProgress: String?
    @State private var showsLibrary = false
    @State private var libraryCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Style references").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("From Library", systemImage: "music.note.list") { showsLibrary = true }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help(libraryCount > 0 ? "Pick albums or songs already in your library" : "Your library has no albums or songs yet")
                Button("Import File…", systemImage: "doc") { importFiles(directories: false) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                Button("Import Folder…", systemImage: "folder") { importFiles(directories: true) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            Text(analysisProgress ?? AudioStyleAnalyzer.capability)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if references.isEmpty {
                Text(libraryCount > 0 ? "Choose an album or song from your library, or a file on this Mac." : "Your library is empty, so import a file or folder. Only the tags in those files are read.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(references) { reference in
                        chip(reference)
                    }
                }
                let skipped = references.filter { $0.promptCue == nil }.count
                let used = min(references.count - skipped, StyleReferenceStore.maxPromptCues)
                if references.count > StyleReferenceStore.maxPromptCues || skipped > 0 {
                    Text("\(used) \(used == 1 ? "reference is" : "references are") sent with the next song\(skipped > 0 ? ". \(skipped) can’t be read and will be skipped" : "").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            libraryCount = (try? model.services.db.reader.read { try Album.fetchCount($0) + Track.fetchCount($0) }) ?? 0
        }
        .sheet(isPresented: $showsLibrary) {
            LibraryStylePicker(existing: references) { picked in
                references = StyleReferenceStore.integrate(current: references, panelAccepted: true, imported: picked)
            }
        }
    }

    private func chip(_ reference: StyleReference) -> some View {
        let missing = reference.availability != .available
        return HStack(spacing: 4) {
            Text(reference.cue.kindLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(reference.cue.title.isEmpty ? "Untitled" : reference.cue.title)
                .lineLimit(1)
            if missing {
                Text(reference.availability == .permissionDenied ? "No access" : "Missing")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            } else if let audio = reference.cue.audio {
                Text(audio.chipLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(audio.status == .measured ? Color.accentColor : .orange)
            }
            Button {
                references.removeAll { $0.id == reference.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(reference.cue.title)")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.7), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func importFiles(directories: Bool) {
        guard let urls = LocalStyleFiles.choose(directories: directories) else { return }
        Task {
            defer { analysisProgress = nil }
            guard let imported = await LocalStyleFiles.references(from: urls, directories: directories, progress: { analysisProgress = $0 }) else { return }
            references = StyleReferenceStore.integrate(current: references, panelAccepted: true, imported: imported)
        }
    }
}

struct LibraryStylePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: [StyleReference]
    var onAdd: ([StyleReference]) -> Void

    @State private var albums: [AlbumInfo] = []
    @State private var songs: [TrackInfo] = []
    @State private var query = ""
    @State private var songsTab = false
    @State private var pickedAlbums = Set<ID>()
    @State private var pickedSongs = Set<ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose albums or songs").font(.title3.weight(.semibold))
            Text("Their genre, mood and style tags are used as a reference. The audio is not uploaded or analyzed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Kind", selection: $songsTab) {
                Text("Albums").tag(false)
                Text("Songs").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
            if albums.isEmpty && songs.isEmpty {
                ContentUnavailableView("No albums or songs yet", systemImage: "music.note", description: Text("Import a file or folder instead."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if songsTab {
                        ForEach(filteredSongs) { info in
                            row(title: info.track.title, subtitle: "\(info.artist.name) — \(info.album.title)", selected: pickedSongs.contains(info.id)) {
                                if pickedSongs.contains(info.id) { pickedSongs.remove(info.id) } else { pickedSongs.insert(info.id) }
                            }
                        }
                    } else {
                        ForEach(filteredAlbums) { info in
                            row(title: info.album.title, subtitle: info.artist.name, selected: pickedAlbums.contains(info.album.id)) {
                                if pickedAlbums.contains(info.album.id) { pickedAlbums.remove(info.album.id) } else { pickedAlbums.insert(info.album.id) }
                            }
                        }
                    }
                }
                .frame(minHeight: 240)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pickedAlbums.isEmpty && pickedSongs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
        .task {
            albums = (try? model.services.db.reader.read { try AppDatabase.albumInfos().fetchAll($0) }) ?? []
            songs = (try? model.services.db.reader.read { try AppDatabase.trackInfos().fetchAll($0) }) ?? []
        }
    }

    private var filteredAlbums: [AlbumInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return albums }
        return albums.filter { $0.album.title.localizedCaseInsensitiveContains(q) || $0.artist.name.localizedCaseInsensitiveContains(q) }
    }

    private var filteredSongs: [TrackInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return songs }
        return songs.filter {
            $0.track.title.localizedCaseInsensitiveContains(q) || $0.artist.name.localizedCaseInsensitiveContains(q)
                || $0.album.title.localizedCaseInsensitiveContains(q)
        }
    }

    private func row(title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func add() {
        var picked: [StyleReference] = []
        let takenAlbums = Set(existing.compactMap { $0.cue.kind == .libraryAlbum ? $0.libraryID : nil })
        let takenSongs = Set(existing.compactMap { $0.cue.kind == .librarySong ? $0.libraryID : nil })
        for info in albums where pickedAlbums.contains(info.album.id) && !takenAlbums.contains(info.album.id) {
            let tracks = (try? model.services.db.tracks(forAlbum: info.album.id)) ?? []
            picked.append(StyleReference(
                cue: StyleReferenceStore.albumCue(info: info, tracks: tracks, id: newID()), libraryID: info.album.id))
        }
        for info in songs where pickedSongs.contains(info.id) && !takenSongs.contains(info.id) {
            picked.append(StyleReference(cue: StyleReferenceStore.songCue(info: info, id: newID()), libraryID: info.id))
        }
        onAdd(picked)
        dismiss()
    }
}

/// Security-scoped file and folder access for style references. Reads tags locally. Never reads audio samples into a request.
@MainActor
enum LocalStyleFiles {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "caf", "ogg", "opus", "mp4"]

    static func choose(directories: Bool) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = !directories
        panel.canCreateDirectories = false
        panel.prompt = "Use as Style"
        panel.message = directories
            ? "Choose a folder. Tags are read, and a short sample of the audio is measured on this Mac. Nothing is uploaded."
            : "Choose songs. Tags are read, and a short sample of the audio is measured on this Mac. Nothing is uploaded."
        if !directories { panel.allowedContentTypes = [.audio] }
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    static func references(from urls: [URL], directories: Bool, progress: @escaping @MainActor (String) -> Void) async -> [StyleReference]? {
        var built: [StyleReference] = []
        for url in urls {
            if Task.isCancelled { return nil }
            guard let reference = await make(url: url, directory: directories || url.hasDirectoryPath, progress: progress) else { return nil }
            built.append(reference)
        }
        return built
    }

    static func refresh(_ reference: StyleReference, progress: @escaping @MainActor (String) -> Void) async throws -> StyleReference {
        guard reference.cue.kind == .file || reference.cue.kind == .folder else { return reference }
        guard let bookmark = reference.bookmark else {
            guard let path = reference.path else {
                return StyleReferenceStore.applyFileResult(reference, result: .failure(.missing))
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return StyleReferenceStore.applyFileResult(reference, result: .failure(.missing))
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                return StyleReferenceStore.applyFileResult(reference, result: .failure(.permissionDenied))
            }
            if reference.cue.kind == .folder {
                let files = audioFiles(in: url)
                return try await applying(reference, urls: files.urls, considered: files.considered, progress: progress)
            }
            let label = reference.cue.title.isEmpty ? url.deletingPathExtension().lastPathComponent : reference.cue.title
            return try await applying(reference, urls: [(label, url)], considered: 1, progress: progress)
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        else {
            return StyleReferenceStore.applyFileResult(reference, result: .failure(.missing))
        }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return StyleReferenceStore.applyFileResult(reference, result: .failure(.missing))
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return StyleReferenceStore.applyFileResult(reference, result: .failure(.permissionDenied))
        }
        if reference.cue.kind == .folder {
            let files = audioFiles(in: url)
            return try await applying(reference, urls: files.urls, considered: files.considered, progress: progress)
        }
        let meta = await tags(of: url)
        let updated = StyleReferenceStore.applyFileResult(reference, result: .success(meta))
        let label = updated.cue.title.isEmpty ? url.deletingPathExtension().lastPathComponent : updated.cue.title
        return try await applying(updated, urls: [(label, url)], considered: 1, progress: progress)
    }

    static func measureLibrary(_ reference: StyleReference, db: AppDatabase, progress: @escaping @MainActor (String) -> Void) async throws -> StyleReference {
        let files = libraryAudio(reference, db: db)
        return try await applying(reference, urls: files.urls, considered: files.considered, progress: progress)
    }

    private static func applying(
        _ reference: StyleReference, urls: [(String, URL)], considered: Int, progress: @escaping @MainActor (String) -> Void
    ) async throws -> StyleReference {
        let report = try await LocalAudioMeasure.measure(urls: urls, considered: considered, cached: reference.cue.audio, progress: progress)
        var updated = reference
        updated.cue.audio = report
        if report.status == .measured || report.status == .silence || report.status == .tooShort {
            updated.cue.note = "File tags, separate from the audio measurement."
        }
        return updated
    }

    private static func libraryAudio(_ reference: StyleReference, db: AppDatabase) -> (urls: [(String, URL)], considered: Int) {
        switch reference.cue.kind {
        case .librarySong:
            guard let id = reference.libraryID,
                let track = try? db.reader.read({ try Track.fetchOne($0, key: id) })
            else { return ([], 0) }
            guard let path = track.audioPath else { return ([], 0) }
            let url = Paths.resolve(path)
            guard FileManager.default.isReadableFile(atPath: url.path) else { return ([], 1) }
            return ([(track.title, url)], 1)
        case .libraryAlbum:
            guard let id = reference.libraryID, let tracks = try? db.tracks(forAlbum: id) else { return ([], 0) }
            let recorded = tracks.compactMap { track -> (String, URL)? in
                guard let path = track.audioPath else { return nil }
                let url = Paths.resolve(path)
                guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
                return (track.title, url)
            }
            return (Array(recorded.prefix(AudioStyleAnalyzer.maxTracks)), recorded.count)
        case .file, .folder:
            return ([], 0)
        }
    }

    private static func audioFiles(in folder: URL) -> (urls: [(String, URL)], considered: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return ([], 0) }
        var found: [(String, URL)] = []
        var extra = 0
        var seen = 0
        while let item = enumerator.nextObject() as? URL {
            seen += 1
            if seen > AudioStyleAnalyzer.maxDirectoryEntries { break }
            guard audioExtensions.contains(item.pathExtension.lowercased()) else { continue }
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if found.count < AudioStyleAnalyzer.maxTracks {
                found.append((item.deletingPathExtension().lastPathComponent, item))
            } else {
                extra += 1
            }
        }
        return (found, found.count + extra)
    }

    private static func make(url: URL, directory: Bool, progress: @escaping @MainActor (String) -> Void) async -> StyleReference? {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return unavailable(url: url, directory: directory, availability: .missing)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return unavailable(url: url, directory: directory, availability: .permissionDenied)
        }
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        if directory {
            let tagged = await folderTags(url)
            if Task.isCancelled { return nil }
            let cue: StyleCue
            do {
                cue = try StyleFolder.summarize(folderName: url.lastPathComponent, files: tagged, isCancelled: {
                    if Task.isCancelled { throw CancellationError() }
                })
            } catch is CancellationError {
                return nil
            } catch {
                cue = StyleCue(kind: .folder, title: url.lastPathComponent, note: "Couldn’t finish reading this folder")
            }
            var reference = StyleReference(cue: cue, bookmark: bookmark, path: url.path)
            let audio = audioFiles(in: url)
            if Task.isCancelled { return nil }
            do {
                reference = try await applying(reference, urls: audio.urls, considered: audio.considered, progress: progress)
            } catch is CancellationError {
                return nil
            } catch {
                return reference
            }
            return reference
        }
        let meta = await tags(of: url)
        let cue = StyleCue(
            kind: .file, title: meta.title.isEmpty ? url.deletingPathExtension().lastPathComponent : meta.title,
            artistName: meta.artist, albumTitle: meta.album, genres: meta.genres,
            note: "File tags, separate from the audio measurement.")
        var reference = StyleReference(cue: cue, bookmark: bookmark, path: url.path)
        do {
            reference = try await applying(reference, urls: [(cue.title, url)], considered: 1, progress: progress)
        } catch is CancellationError {
            return nil
        } catch {
            return reference
        }
        return reference
    }

    private static func unavailable(url: URL, directory: Bool, availability: StyleReference.Availability) -> StyleReference {
        var reference = StyleReference(
            cue: StyleCue(kind: directory ? .folder : .file, title: url.lastPathComponent), path: url.path, availability: availability)
        reference.availability = availability
        return reference
    }

    private static func folderTags(_ folder: URL) async -> [StyleFileMeta] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var metas: [StyleFileMeta] = []
        var seen = 0
        while let item = enumerator.nextObject() as? URL {
            if Task.isCancelled || metas.count >= 40 || seen >= 400 { break }
            seen += 1
            guard audioExtensions.contains(item.pathExtension.lowercased()) else { continue }
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            metas.append(await tags(of: item))
        }
        return metas
    }

    /// Title, artist, album and genre from the file's tags. The filename is the title when tags are empty.
    private static func tags(of url: URL) async -> StyleFileMeta {
        let asset = AVURLAsset(url: url)
        var items = (try? await asset.load(.commonMetadata)) ?? []
            if let formats = try? await asset.load(.availableMetadataFormats) {
                for format in formats {
                    if let more = try? await asset.loadMetadata(for: format) { items.append(contentsOf: more) }
                }
            }
        var title = ""
        var artist = ""
        var album = ""
        var genres: [String] = []
        for item in items {
            let key = ((item.commonKey?.rawValue) ?? (item.identifier?.rawValue ?? "")).lowercased()
            guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
            if key.contains("title"), title.isEmpty, !key.contains("album") { title = value }
            else if key.contains("artist"), artist.isEmpty, !key.contains("album") { artist = value }
            else if key.contains("album"), album.isEmpty { album = value }
            else if key.contains("genre") { genres.append(value) }
        }
        if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
        return StyleFileMeta(title: title, artist: artist, album: album, genres: genres)
    }
}

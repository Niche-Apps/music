import GRDB
import StandardKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryState.self) private var library
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                Label("Browse", systemImage: "square.grid.2x2").tag(SidebarItem.browse)
                Label("Create", systemImage: "sparkles").tag(SidebarItem.create)
            }
            Section("Library") {
                Label("Recently Added", systemImage: "clock").tag(SidebarItem.recentlyAdded)
                Label("Artists", systemImage: "music.microphone").tag(SidebarItem.artists)
                Label("Albums", systemImage: "square.stack").tag(SidebarItem.albums)
                Label("Songs", systemImage: "music.note").tag(SidebarItem.songs)
                Label("Favorites", systemImage: "star").tag(SidebarItem.favorites)
            }
            Section("Playlists") {
                ForEach(library.playlists) { playlist in
                    playlistRow(playlist).tag(SidebarItem.playlist(playlist.id))
                }
                Button {
                    if let p = model.newPlaylist() {
                        model.selection = .playlist(p.id)
                        startRename(p)
                    }
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                UpdateAvailableButton()
                StudioStatusPanel()
            }
        }
    }

    @ViewBuilder private func playlistRow(_ playlist: Playlist) -> some View {
        if library.renamingPlaylist == playlist.id {
            TextField("Playlist Name", text: $renameText)
                .focused($renameFocused)
                .onSubmit { commitRename(playlist) }
                .onChange(of: renameFocused) { _, focused in if !focused { commitRename(playlist) } }
                .onExitCommand { library.renamingPlaylist = nil }
        } else {
            Label(playlist.name, systemImage: "music.note.list")
                .dropDestination(for: String.self) { ids, _ in
                    let trackIDs = ids.filter { !$0.contains(" ") }
                    guard !trackIDs.isEmpty else { return false }
                    model.add(trackIDs, to: playlist)
                    return true
                }
                .contextMenu {
                    Button("Play", systemImage: "play") { playPlaylist(playlist, shuffled: false) }
                    Button("Shuffle", systemImage: "shuffle") { playPlaylist(playlist, shuffled: true) }
                    Divider()
                    Button("Rename", systemImage: "pencil") { startRename(playlist) }
                    Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                        if model.selection == .playlist(playlist.id) { model.selection = .home }
                        try? model.services.db.deletePlaylist(playlist.id)
                    }
                }
        }
    }

    private func startRename(_ playlist: Playlist) {
        renameText = playlist.name
        library.renamingPlaylist = playlist.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename(_ playlist: Playlist) {
        guard library.renamingPlaylist == playlist.id else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != playlist.name { try? model.services.db.renamePlaylist(playlist.id, to: name) }
        library.renamingPlaylist = nil
    }

    private func playPlaylist(_ playlist: Playlist, shuffled: Bool) {
        let entries = (try? model.services.db.reader.read { try LibraryQuery.playlistTracks($0, playlist.id) }) ?? []
        model.player.play(trackIDs: entries.map(\.info.id), context: .playlist(playlist.id, playlist.name), shuffled: shuffled)
    }
}

/// "Update Available" at the bottom of the sidebar once Sparkle has found a new version. One click
/// installs the downloaded update and relaunches.
struct UpdateAvailableButton: View {
    @State private var updater = AppUpdater.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let pending = updater.pending {
            Button { updater.installUpdate() } label: {
                HStack(spacing: 8) {
                    if pending == .installing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white, Color.accentColor)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pending == .installing ? "Installing Update…" : "Update Available")
                            .font(.system(size: 11.5, weight: .semibold))
                        if let detail = detail(pending) {
                            Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pending == .installing)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .help("Install the new version and relaunch")
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func detail(_ pending: AppUpdater.Pending) -> String? {
        switch pending {
        case .ready(let v): "Version \(v) · Click to restart"
        case .available(let v): "Version \(v)"
        case .installing: nil
        }
    }
}

/// Compact live status at the bottom of the sidebar: library building and the studio.
struct StudioStatusPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LibraryState.self) private var library
    @State private var queuedCount = 0

    var body: some View {
        let status = model.buildStatus
        let building = [.planning, .writing, .waiting].contains(status.phase)
        let active = model.recording.active
        if building || active != nil || status.phase == .failed {
            VStack(spacing: 8) {
                if building || status.phase == .failed {
                    Button { model.selection = .create } label: { buildRow(status) }
                        .buttonStyle(.plain)
                        .help(status.activity.isEmpty ? status.title : status.activity)
                }
                if let active {
                    let listening = model.player.current?.track.id == active.trackID
                    Button {
                        if listening {
                            withAnimation(.smooth(duration: 0.45)) { model.showsNowPlaying = true }
                        } else {
                            library.reveal = active.trackID
                            model.show(.album(active.albumID))
                        }
                    } label: { studioRow(active) }
                    .buttonStyle(.plain)
                    .help(listening ? "Watch “\(active.title)” being recorded" : "Show “\(active.title)” in its album")
                    .contextMenu {
                        Button("Now Playing", systemImage: "arrow.up.left.and.arrow.down.right") { model.showsNowPlaying = true }
                            .disabled(model.player.current == nil)
                        Button("Show in Album", systemImage: "square.stack") {
                            library.reveal = active.trackID
                            model.show(.album(active.albumID))
                        }
                        Divider()
                        Button("Stop Recording", systemImage: "stop.fill") { model.stopRecording() }
                    }
                }
            }
            .padding(10)
            .background(LegibilityScrim(shape: RoundedRectangle(cornerRadius: 12), color: Color(nsColor: .windowBackgroundColor), opacity: 1))
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .animation(.smooth, value: active?.trackID)
        }
    }

    private func buildRow(_ status: BuildStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: status.phase == .failed ? "exclamationmark.triangle.fill" : "sparkles")
                    .foregroundStyle(status.phase == .failed ? Color.orange : Color.accentColor)
                    .symbolEffect(.pulse, isActive: status.phase != .failed && !reduceMotion)
                    .accessibilityHidden(true)
                Text(status.phase == .failed ? "Library paused" : status.title.isEmpty ? "Writing new artists" : status.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if status.artistsTotal > 0 {
                    Text("\(status.artistsReady)/\(status.artistsTotal)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: status.fraction).controlSize(.mini)
            Text(status.phase == .failed ? status.error ?? "Something went wrong." : status.phase == .waiting ? waitingText(status) : status.activity)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.phase == .failed ? "Library paused" : status.title.isEmpty ? "Writing new artists" : status.title)
        .accessibilityValue(buildValue(status))
    }

    private func buildValue(_ status: BuildStatus) -> String {
        var parts: [String] = []
        if status.artistsTotal > 0 { parts.append("\(status.artistsReady) of \(status.artistsTotal) artists ready") }
        let detail = status.phase == .failed ? status.error ?? "Something went wrong." : status.phase == .waiting ? waitingText(status) : status.activity
        if !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: ", ")
    }

    private func waitingText(_ status: BuildStatus) -> String {
        guard let until = status.waitingUntil else { return "Waiting for ChatGPT" }
        return "Resting until \(until.formatted(date: .omitted, time: .shortened)) (usage limit)"
    }

    private func studioRow(_ active: RecordingQueue.Activity) -> some View {
        HStack(spacing: 9) {
            RecordingRing(fraction: active.fraction, lineWidth: 2.2)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Recording “\(active.title)”")
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text([active.stageLabel, Format.remaining(active.remaining)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording “\(active.title)”")
        .accessibilityValue(Spoken.recording(fraction: active.fraction, stage: active.stageLabel, remaining: active.remaining))
    }
}

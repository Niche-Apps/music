import AppKit
import GRDB
import StandardKit
import SwiftUI

/// The menu bar extra's window: now playing, the studio, library building and quick actions.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            MenuBarNowPlaying()
            if model.recording.active != nil || model.recording.waitingCount > 0 {
                MenuBarDivider()
                MenuBarStudioStatus()
            }
            if model.buildStatus.isRunning {
                MenuBarDivider()
                MenuBarBuildStatus()
            }
            MenuBarDivider()
            VStack(spacing: 0) {
                MenuBarAction("Open Standard Music", symbol: "macwindow", shortcut: "⌘0") {
                    dismissMenu()
                    AppActions.showMainWindow(openWindow: openWindow)
                }
                MenuBarAction("MiniPlayer", symbol: "rectangle.inset.bottomright.filled", shortcut: "⇧⌘M") {
                    dismissMenu()
                    openWindow(id: WindowID.mini)
                    NSApp.activate()
                }
                MenuBarAction("Create New Music…", symbol: "sparkles", shortcut: "⇧⌘N") {
                    dismissMenu()
                    AppActions.createMusic(model, openWindow: openWindow)
                }
                .disabled(model.phase != .library)
                MenuBarAction("Settings…", symbol: "gearshape", shortcut: "⌘,") {
                    dismissMenu()
                    NSApp.activate()
                    openSettings()
                }
            }
            .padding(.vertical, 5)
            MenuBarDivider()
            MenuBarAction("Quit Standard Music", symbol: "power", shortcut: "⌘Q") { AppActions.quit() }
                .padding(.vertical, 5)
        }
        .padding(.horizontal, 5)
        .padding(.bottom, 1)
        .frame(width: 320)
    }

    private func dismissMenu() {
        NSApp.keyWindow?.close()
    }
}

extension RecordingQueue {
    /// Songs in line behind the one recording now.
    var waitingCount: Int {
        var seen = Set<ID>()
        return (playbackDemand + requested).filter { $0 != active?.trackID && failures[$0] == nil && seen.insert($0).inserted }.count
    }
}

extension BuildStatus {
    var isRunning: Bool { phase == .planning || phase == .writing || phase == .waiting }
}

struct MenuBarDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 9).padding(.vertical, 1)
    }
}

// MARK: - Now playing

struct MenuBarNowPlaying: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var shuffleCandidates = 0

    var body: some View {
        let player = model.player
        Group {
            if let info = player.current {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            NSApp.keyWindow?.close()
                            AppActions.goToCurrentSong(model, openWindow: openWindow)
                        } label: {
                            ArtworkView(source: .album(info.album), size: 64, cornerRadius: 8)
                        }
                        .buttonStyle(.plain)
                        .help("Go to Album")
                        .accessibilityLabel("Go to Album")
                        .accessibilityValue(Spoken.albumCover(info.album.title, by: info.artist.name))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.track.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(info.artist.name)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(info.album.title)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .lineLimit(1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Now playing, \(info.track.title), \(info.artist.name), \(info.album.title)")
                        Spacer(minLength: 0)
                        FavoriteButton(isFavorite: info.track.isFavorite) { model.toggleFavorite(track: info.track.id) }
                            .font(.system(size: 14))
                    }
                    PlaybackScrubber(height: 4)
                    HStack {
                        Button { player.shuffle.toggle() } label: {
                            Image(systemName: "shuffle")
                                .foregroundStyle(player.shuffle ? Color.accentColor : .secondary)
                        }
                        .help(player.shuffle ? "Shuffle is on" : "Shuffle")
                        .accessibilityLabel("Shuffle")
                        .accessibilityValue(player.shuffle ? "On" : "Off")
                        .accessibilityAddTraits(player.shuffle ? .isSelected : [])
                        Spacer()
                        TransportControls(size: 18, spacing: 24)
                            .foregroundStyle(.primary)
                        Spacer()
                        Button { player.repeatMode = player.repeatMode.next } label: {
                            Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                                .foregroundStyle(player.repeatMode == .off ? Color.secondary : .accentColor)
                        }
                        .help(player.repeatMode.help)
                        .accessibilityLabel("Repeat")
                        .accessibilityValue(player.repeatMode.spokenValue)
                        .accessibilityAddTraits(player.repeatMode == .off ? [] : .isSelected)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                }
                .padding(12)
                .background {
                    ArtworkView(source: .album(info.album), cornerRadius: 0, shadow: false)
                        .frame(width: 400, height: 400)
                        .blur(radius: 50)
                        .opacity(0.35)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    LegibilityScrim(color: Color(nsColor: .windowBackgroundColor), opacity: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 5)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing Playing").font(.system(size: 13, weight: .semibold))
                        Text(shuffleCandidates > 0 ? "\(shuffleCandidates) recorded songs ready to play" : "Pick an album and it’s recorded as you listen")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if shuffleCandidates > 0 {
                        Button {
                            shuffleRecorded()
                        } label: {
                            Image(systemName: "shuffle")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .help("Shuffle your recorded songs")
                        .accessibilityLabel("Shuffle your recorded songs")
                    }
                }
                .padding(12)
                .padding(.top, 5)
                .observing(model.services.db, { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE status = 'ready' AND audioPath IS NOT NULL") ?? 0
                }) { shuffleCandidates = $0 }
            }
        }
    }

    private func shuffleRecorded() {
        let ids = (try? model.services.db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM track WHERE status = 'ready' AND audioPath IS NOT NULL ORDER BY RANDOM() LIMIT 200")
        }) ?? []
        model.player.play(trackIDs: ids, context: .songs("Recorded Songs"), shuffled: true)
    }
}

// MARK: - Studio

struct MenuBarStudioStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recording = model.recording
        let waiting = recording.waitingCount
        HStack(alignment: .center, spacing: 10) {
            RecordingRing(fraction: recording.active?.fraction ?? 0, lineWidth: 2.5)
                .frame(width: 22, height: 22)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 2) {
                if let active = recording.active {
                    Text("Recording “\(active.title)”")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text([active.stageLabel, Format.remaining(active.remaining), waiting > 0 ? "\(waiting) more in line" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Getting the studio ready")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(waiting) song\(waiting == 1 ? "" : "s") waiting to be recorded")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let active = recording.active, active.fraction > 0.005 {
                Text(active.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .animation(.smooth, value: recording.active?.trackID)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recording.active.map { "Recording “\($0.title)”" } ?? "Getting the studio ready")
        .accessibilityValue(studioValue(recording.active, waiting: waiting))
    }

    private func studioValue(_ active: RecordingQueue.Activity?, waiting: Int) -> String {
        let line = waiting > 0 ? "\(waiting) more in line" : nil
        guard let active else { return "\(waiting) song\(waiting == 1 ? "" : "s") waiting to be recorded" }
        return [Spoken.recording(fraction: active.fraction, stage: active.stageLabel, remaining: active.remaining), line]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Library building

struct MenuBarBuildStatus: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let status = model.buildStatus
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    .frame(width: 22)
                    .padding(.leading, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title.isEmpty ? "Discovering new artists" : status.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle(status))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if status.artistsTotal > 0 {
                    Text("\(status.artistsReady)/\(status.artistsTotal)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if status.artistsTotal > 0 {
                ProgressView(value: status.fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .padding(.leading, 34)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.title.isEmpty ? "Discovering new artists" : status.title)
        .accessibilityValue((status.artistsTotal > 0 ? "\(status.artistsReady) of \(status.artistsTotal) artists ready, " : "") + subtitle(status))
    }

    private func subtitle(_ status: BuildStatus) -> String {
        if status.phase == .waiting, let until = status.waitingUntil {
            return "Paused for ChatGPT limits · resumes \(until.formatted(.relative(presentation: .named)))"
        }
        return status.activity.isEmpty ? "Writing artists and albums" : status.activity
    }
}

// MARK: - Actions

struct MenuBarAction: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, symbol: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(hovering ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                }
            }
            .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 && isEnabled }
    }
}

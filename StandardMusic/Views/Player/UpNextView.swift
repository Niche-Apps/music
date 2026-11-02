import GRDB
import StandardKit
import SwiftUI

/// Inspector: what's playing, what's next (with studio state), autoplay and history.
struct UpNextView: View {
    @Environment(AppModel.self) private var model
    @State private var infos: [ID: TrackInfo] = [:]
    @State private var showsHistory = false

    var body: some View {
        let player = model.player
        let upNext = player.upNext.filter { !$0.isAutoplay }
        let autoplay = player.upNext.filter(\.isAutoplay)
        List {
            if let current = player.current {
                Section {
                    QueueRow(info: current, isCurrent: true)
                } header: {
                    Text("Now Playing")
                }
            }
            Section {
                if upNext.isEmpty {
                    Text(player.current == nil ? "Play an album and it will show up here." : "Nothing queued. Use Play Next or Play Later from any song’s menu.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowSeparator(.hidden)
                }
                ForEach(upNext) { entry in
                    row(entry)
                }
                .onMove { from, to in move(from, to, among: upNext) }
            } header: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Up Next")
                        if let context = player.context {
                            Text("Playing from \(context.label)")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                    Spacer()
                    if !player.upNext.isEmpty {
                        Button("Clear") { player.clearUpNext() }
                            .buttonStyle(.link)
                            .textCase(nil)
                            .accessibilityLabel("Clear Up Next")
                    }
                }
            }
            Section {
                if player.autoplay {
                    if autoplay.isEmpty {
                        Text("A similar album starts after the last song.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(autoplay) { entry in row(entry) }
                } else {
                    Text("Autoplay is off. When the queue ends, the music stops.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Autoplay")
                        Text("Keeps similar music playing")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Toggle(isOn: Binding(get: { player.autoplay }, set: { player.autoplay = $0 })) {
                        Image(systemName: "infinity")
                    }
                    .toggleStyle(.button)
                    .help(player.autoplay ? "Turn Autoplay off" : "Turn Autoplay on")
                    .accessibilityLabel("Autoplay")
                }
            }
            if !player.history.isEmpty {
                Section(isExpanded: $showsHistory) {
                    ForEach(player.history.reversed()) { entry in row(entry) }
                } header: {
                    Text("History")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .observing(model.services.db, id: player.queue.map(\.trackID)) { [ids = Array(Set(player.queue.map(\.trackID)))] db in
            try AppDatabase.trackInfos().filter(keys: ids).fetchAll(db)
        } update: { list in
            infos = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    @ViewBuilder private func row(_ entry: PlayerModel.Entry) -> some View {
        if let info = infos[entry.trackID] {
            QueueRow(info: info)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.player.jump(to: entry) }
                .contextMenu {
                    Button("Play Now", systemImage: "play") { model.player.jump(to: entry) }
                    Button("Remove from Up Next", systemImage: "minus.circle") { model.player.remove(entry) }
                    Divider()
                    Button("Go to Album", systemImage: "square.stack") { model.show(.album(info.album.id)) }
                    Button("Go to Artist", systemImage: "music.microphone") { model.show(.artist(info.artist.id)) }
                }
                .swipeActions {
                    Button("Remove", systemImage: "trash", role: .destructive) { model.player.remove(entry) }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.player.jump(to: entry) }
                .accessibilityAction(named: "Play Now") { model.player.jump(to: entry) }
                .accessibilityAction(named: "Remove from Up Next") { model.player.remove(entry) }
                .accessibilityAction(named: "Go to Album") { model.show(.album(info.album.id)) }
                .accessibilityAction(named: "Go to Artist") { model.show(.artist(info.artist.id)) }
        }
    }

    /// Up Next offsets are relative to the visible (non-autoplay) list, which leads the queue.
    private func move(_ from: IndexSet, _ to: Int, among list: [PlayerModel.Entry]) {
        model.player.move(fromOffsets: from, toOffset: to)
    }
}

struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let info: TrackInfo
    var isCurrent = false

    var body: some View {
        let state = model.liveState(of: info.track)
        HStack(spacing: 10) {
            ZStack {
                ArtworkView(source: .album(info.album), size: 36, cornerRadius: 4, shadow: false)
                    .opacity(state.isUnrecorded && !isCurrent ? 0.6 : 1)
                if state != .ready && state != .unrecorded {
                    RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.4))
                    TrackLeadingCell(state: state, number: nil)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.track.title).font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular)).lineLimit(1)
                Group {
                    switch state {
                    case .recording, .waiting, .queued, .failed:
                        TrackStatusCaption(state: state, trackID: info.id)
                    case .unrecorded:
                        Text("\(info.artist.name) · Records when it’s up").foregroundStyle(.secondary)
                    default:
                        Text(info.artist.name).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Format.duration(info.track.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCurrent ? "Now playing, \(info.track.title), \(info.artist.name)" : "\(info.track.title), \(info.artist.name)")
        .accessibilityValue([Spoken.duration(info.track.duration), state.spokenDescription].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

import GRDB
import StandardKit
import SwiftUI

/// Just what the Songs table shows. Fetching full `TrackInfo`s (bios, souls, notes, JSON arrays)
/// for thousands of rows made the table slow to open and to scroll.
struct SongRow: Codable, FetchableRecord, Hashable, Identifiable, Sendable {
    var id: ID
    var title: String
    var duration: Double?
    var playCount: Int
    var isFavorite: Bool
    var status: String
    var audioPath: String?
    var discNumber: Int
    var trackNumber: Int
    var albumID: ID
    var albumTitle: String
    var releaseYear: Int
    var artistID: ID
    var artistName: String
    var artistSort: String

    var isPlayable: Bool { status == TrackStatus.ready.rawValue && audioPath != nil }
    var durationValue: Double { duration ?? -1 }
    var favoriteValue: Int { isFavorite ? 1 : 0 }
    var statusValue: Int { isPlayable ? 0 : 1 }

    static func fetchAll(_ db: Database) throws -> [SongRow] {
        try SongRow.fetchAll(
            db,
            sql: """
                SELECT t.id, t.title, t.duration, t.playCount, t.isFavorite, t.status, t.audioPath, t.discNumber,
                       t.trackNumber, al.id AS albumID, al.title AS albumTitle, al.releaseYear,
                       ar.id AS artistID, ar.name AS artistName, ar.sortName AS artistSort
                FROM track t JOIN album al ON al.id = t.albumID JOIN artist ar ON ar.id = t.artistID
                WHERE al.status = 'ready'
                """)
    }
}

/// Every song in the library, recorded or not, in a sortable table.
struct SongsView: View {
    enum Filter: String, CaseIterable { case all = "All", recorded = "Recorded", unrecorded = "Not Recorded" }

    @Environment(AppModel.self) private var model
    @State private var songs: [SongRow] = []
    @State private var rows: [SongRow] = []
    @State private var loaded = false
    @State private var selection = Set<ID>()
    @State private var sortOrder = [KeyPathComparator(\SongRow.artistSort), KeyPathComparator(\SongRow.releaseYear)]
    @AppStorage("songsFilter") private var filter = Filter.all
    @State private var text = ""

    var body: some View {
        Group {
            if loaded && songs.isEmpty {
                LibraryEmptyView(title: "No songs yet", systemImage: "music.note", message: "Songs appear here as albums are written.")
            } else {
                VStack(spacing: 0) {
                    header
                    table
                }
            }
        }
        .navigationTitle("Songs")
        .observing(model.services.db, immediate: false) { db in try SongRow.fetchAll(db) } update: { list in
            songs = list
            loaded = true
            refresh()
        }
        .onChange(of: sortOrder) { refresh() }
        .onChange(of: filter) { refresh() }
        .onChange(of: text) { refresh() }
    }

    /// Filters and sorts once per input change instead of on every body evaluation.
    private func refresh() {
        var list = songs
        switch filter {
        case .all: break
        case .recorded: list = list.filter(\.isPlayable)
        case .unrecorded: list = list.filter { !$0.isPlayable }
        }
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(t) || $0.artistName.localizedCaseInsensitiveContains(t)
                    || $0.albumTitle.localizedCaseInsensitiveContains(t)
            }
        }
        if sortOrder.first?.keyPath == \SongRow.artistSort {
            // Artist sort keeps albums together and tracks in order.
            let ascending = sortOrder.first?.order == .forward
            list.sort {
                let a = ($0.artistSort, $0.releaseYear, $0.albumTitle, $0.discNumber, $0.trackNumber)
                let b = ($1.artistSort, $1.releaseYear, $1.albumTitle, $1.discNumber, $1.trackNumber)
                return ascending ? a < b : a > b
            }
        } else {
            list.sort(using: sortOrder)
        }
        rows = list
    }

    private var header: some View {
        let recorded = songs.reduce(0) { $0 + ($1.isPlayable ? 1 : 0) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                PageHeader(title: "Songs", subtitle: loaded ? "\(songs.count) songs · \(recorded) recorded" : " ")
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Filter", text: $text)
                    .accessibilityLabel("Filter songs")
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            LibraryBuildingBanner()
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", value: \SongRow.statusValue) { row in
                SongStatusCell(model: model, row: row)
            }
            .width(26)
            TableColumn("Title", value: \SongRow.title) { row in
                Text(row.title)
                    .foregroundStyle(row.isPlayable ? .primary : .secondary)
            }
            .width(min: 140, ideal: 260)
            TableColumn("Artist", value: \SongRow.artistSort) { row in
                Text(row.artistName).foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 170)
            TableColumn("Album", value: \SongRow.albumTitle) { row in
                Text(row.albumTitle).foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 200)
            TableColumn("Time", value: \SongRow.durationValue) { row in
                Text(Format.duration(row.duration))
                    .monospacedDigit()
                    .foregroundStyle(row.isPlayable ? .secondary : .tertiary)
            }
            .width(54)
            TableColumn("Plays", value: \SongRow.playCount) { row in
                Text(row.playCount > 0 ? "\(row.playCount)" : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(46)
            TableColumn(Text(Image(systemName: "star")), value: \SongRow.favoriteValue) { row in
                // A plain image keeps thousands of rows cheap; FavoriteButton animates symbol changes.
                Image(systemName: row.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(row.isFavorite ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleFavorite(track: row.id) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(row.isFavorite ? .isSelected : [])
                    .accessibilityLabel("Favorite")
                    .accessibilityAction { model.toggleFavorite(track: row.id) }
            }
            .width(26)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: ID.self) { ids in
            // Full details only for the rows the menu is about.
            let infos = (try? model.services.db.reader.read { db in
                try AppDatabase.trackInfos().filter(keys: ids).fetchAll(db)
            }) ?? []
            if infos.count == 1, let info = infos.first {
                TrackMenuItems(info: info)
            } else if !infos.isEmpty {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext(infos) }
                Button("Play Later", systemImage: "text.line.last.and.arrowtriangle.forward") { model.playLater(infos) }
                let unrecorded = infos.filter { !$0.track.isPlayable }.map(\.id)
                if !unrecorded.isEmpty {
                    Button("Record \(unrecorded.count) Songs", systemImage: "record.circle") { model.record(unrecorded) }
                }
                PlaylistMenu { infos.map(\.id) }
                Divider()
                Button("Copy", systemImage: "doc.on.doc") { model.copy(infos.map(\.copyText).joined(separator: "\n")) }
            }
        } primaryAction: { ids in
            guard let row = rows.first(where: { ids.contains($0.id) }) else { return }
            guard row.isPlayable else {
                model.toast = "“\(row.title)” isn’t recorded yet — play the album to record it."
                return
            }
            model.player.play(trackIDs: rows.filter(\.isPlayable).map(\.id), startingAt: row.id, context: .songs("Songs"))
        }
    }
}

/// Table cells are hosted by AppKit and can lose inherited environment when rows are rebuilt
/// (e.g. switching the Recorded filter), so the model is passed in rather than read from it.
struct SongStatusCell: View {
    let model: AppModel
    let row: SongRow

    var body: some View {
        let state = model.liveState(id: row.id, isPlayable: row.isPlayable, failed: row.status == TrackStatus.failed.rawValue)
        Group {
            switch state {
            case .ready:
                EmptyView()
            case .unrecorded:
                Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
                    .help("Not recorded yet — play the album to record it")
            default:
                TrackLeadingCell(state: state, number: nil)
            }
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.spokenDescription ?? "Recorded")
    }
}

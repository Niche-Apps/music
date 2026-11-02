import GRDB
import StandardKit
import SwiftUI

struct AlbumsView: View {
    enum Sort: String, CaseIterable {
        case artist = "Artist", title = "Title", year = "Year", recent = "Recently Added"
    }

    @Environment(AppModel.self) private var model
    @AppStorage("albumsSort") private var sort = Sort.artist
    @State private var albums: [AlbumInfo] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded && albums.isEmpty {
                LibraryEmptyView(title: "No albums yet", systemImage: "square.stack", message: "Albums appear here as your library is written.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .lastTextBaseline) {
                            PageHeader(title: "Albums", subtitle: "\(albums.count) album\(albums.count == 1 ? "" : "s")")
                            Picker("Sort By", selection: $sort) {
                                ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                        LibraryBuildingBanner()
                        AlbumGrid(albums: sorted)
                    }
                    .padding(Metrics.pagePadding)
                }
            }
        }
        .navigationTitle("Albums")
        .observing(model.services.db, immediate: false) { db in try LibraryQuery.albums().fetchAll(db) } update: { list in
            albums = list
            loaded = true
        }
    }

    private var sorted: [AlbumInfo] {
        switch sort {
        case .artist:
            albums.sorted { ($0.artist.sortName, $0.album.releaseYear) < ($1.artist.sortName, $1.album.releaseYear) }
        case .title:
            albums.sorted { $0.album.title.localizedStandardCompare($1.album.title) == .orderedAscending }
        case .year:
            albums.sorted { ($0.album.releaseYear, $0.album.title) > ($1.album.releaseYear, $1.album.title) }
        case .recent:
            albums.sorted { $0.album.createdAt > $1.album.createdAt }
        }
    }
}

/// Albums grouped by when they arrived in the library.
struct RecentlyAddedView: View {
    @Environment(AppModel.self) private var model
    @State private var albums: [AlbumInfo] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded && albums.isEmpty {
                LibraryEmptyView(title: "Nothing added yet", systemImage: "clock", message: "New albums land here as they’re written.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        PageHeader(title: "Recently Added")
                        LibraryBuildingBanner()
                        ForEach(groups, id: \.0) { title, items in
                            VStack(alignment: .leading, spacing: 14) {
                                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                                    .accessibilityHeading()
                                AlbumGrid(albums: items)
                            }
                        }
                    }
                    .padding(Metrics.pagePadding)
                }
            }
        }
        .navigationTitle("Recently Added")
        .observing(model.services.db, immediate: false) { db in
            try LibraryQuery.albums().order(Column("createdAt").desc).limit(300).fetchAll(db)
        } update: { list in
            albums = list
            loaded = true
        }
    }

    private var groups: [(String, [AlbumInfo])] {
        let cal = Calendar.current
        var result: [(String, [AlbumInfo])] = []
        for info in albums {
            let date = info.album.createdAt
            let title =
                cal.isDateInToday(date) ? "Today"
                : cal.isDateInYesterday(date) ? "Yesterday"
                : date > Date().addingTimeInterval(-7 * 86_400) ? "This Week"
                : date > Date().addingTimeInterval(-30 * 86_400) ? "This Month"
                : date.formatted(.dateTime.month(.wide).year())
            if result.last?.0 == title { result[result.count - 1].1.append(info) } else { result.append((title, [info])) }
        }
        return result
    }
}

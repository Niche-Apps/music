import AppKit
import GRDB
import StandardKit
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var library = LibraryState()
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var lastSelection: SidebarItem = .home
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            NavigationStack(path: $model.path) {
                DetailRoot(selection: model.selection ?? .home)
                    .toolbar { PlayerToolbar(model: model, library: library) }
                    .navigationDestination(for: Route.self) { route in
                        RouteView(route: route)
                            .toolbar { PlayerToolbar(model: model, library: library) }
                    }
            }
            .overlay(alignment: .bottom) { toast }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .toolbar(removing: .title)
        .inspector(isPresented: inspectorBinding) {
            Group {
                if model.showsLyrics { LyricsView() } else { UpNextView() }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .overlay {
            if model.showsNowPlaying {
                NowPlayingView()
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environment(library)
        .sheet(item: $model.shareRequest) { ShareSheet(request: $0) }
        .sheet(item: $model.pendingImport, onDismiss: { model.cancelImport() }) { ImportSheet(pending: $0) }
        .dropDestination(for: URL.self) { urls, _ in
            let shares = urls.filter { $0.pathExtension == ShareManifest.fileExtension }
            guard let first = shares.first else { return false }
            model.openShareFile(first)
            return true
        }
        .onChange(of: model.showsQueue || model.showsLyrics) { _, shown in
            // Make room for the inspector on narrow windows, like Music does.
            guard let width = NSApp.keyWindow?.frame.width else { return }
            if shown, width < 1250, columns != .detailOnly {
                withAnimation(.smooth) { columns = .detailOnly }
            } else if !shown, columns == .detailOnly {
                withAnimation(.smooth) { columns = .all }
            }
        }
        .background { shortcuts }
        .onChange(of: model.selection) { old, new in
            model.path = []
            if let new, new != .search { lastSelection = new }
        }
        .onChange(of: model.revealRequest) { _, id in
            guard let id else { return }
            library.reveal = id
            model.revealRequest = nil
        }
        .onChange(of: model.searchText) { _, text in
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                if model.selection != .search { model.selection = .search }
            } else if model.selection == .search {
                model.selection = lastSelection
            }
        }
        .observing(model.services.db) { db in
            try Playlist.order(Column("createdAt")).fetchAll(db)
        } update: { library.playlists = $0 }
        #if DEBUG
        .task { await DebugSnapshots.run(model: model, library: library) }
        #endif
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { model.showsLyrics || model.showsQueue },
            set: { shown in
                if !shown {
                    model.showsLyrics = false
                    model.showsQueue = false
                }
            })
    }

    @ViewBuilder private var toast: some View {
        if let message = model.toast {
            ToastView(message: message)
                .padding(.bottom, 22)
                .padding(.horizontal, 40)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { withAnimation { model.toast = nil } }
                .accessibilityAddTraits(.isStaticText)
                .task(id: message) {
                    // VoiceOver: speak toasts, which otherwise appear silently and vanish.
                    AccessibilityNotification.Announcement(message).post()
                    try? await Task.sleep(for: .seconds(max(3, Double(message.count) / 18)))
                    withAnimation(.smooth) { if model.toast == message { model.toast = nil } }
                }
        }
    }

    /// Window-level keyboard shortcuts that don't belong in a menu.
    private var shortcuts: some View {
        Group {
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("Back") { if !model.path.isEmpty { model.path.removeLast() } }
                .keyboardShortcut("[", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Root screen for a sidebar item.
struct DetailRoot: View {
    let selection: SidebarItem

    var body: some View {
        switch selection {
        case .home: HomeView()
        case .browse: BrowseView()
        case .create: CreateView()
        case .recentlyAdded: RecentlyAddedView()
        case .artists: ArtistsView()
        case .albums: AlbumsView()
        case .songs: SongsView()
        case .favorites: FavoritesView()
        case .playlist(let id): PlaylistView(playlistID: id)
        case .search: SearchView()
        }
    }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .album(let id): AlbumView(albumID: id)
        case .artist(let id): ArtistView(artistID: id)
        case .genre(let name): GenreView(genre: name)
        case .playlist(let id): PlaylistView(playlistID: id)
        case .shelf(let key): ShelfView(key: key)
        }
    }
}

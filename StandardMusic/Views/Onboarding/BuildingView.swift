import GRDB
import StandardKit
import SwiftUI

/// The long wait while the library is written, made into a show. Each stage of generation appears as
/// soon as it lands: the roster (names), then portraits, then album covers, then ready artists.
struct BuildingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var artists: [Artist] = []
    @State private var covers: [ID: Album] = [:]
    /// Album covers and portraits in the order this screen saw them arrive, so new ones never reshuffle old ones.
    @State private var coverOrder: [ID] = []
    @State private var portraitOrder: [ID] = []
    @State private var spotlight: ID?
    @State private var retrying = false

    private static let readyThreshold = 6

    @State private var recorded: [Track] = []
    /// The "while you wait" song and whether this is the listener's first library (it only exists for that one).
    @State private var opener = OpenerSong.none
    @State private var firstLibrary = false

    private struct Snapshot: Equatable, Sendable {
        var artists: [Artist]
        var covers: [Album]
        var recorded: [Track]
    }

    var body: some View {
        ZStack {
            AmbientBackground(intensity: 0.6)
            CoverWall(albums: coverOrder.compactMap { covers[$0] })
            RadialGradient(
                colors: [.black.opacity(0.82), .black.opacity(0.55), .black.opacity(0.2)], center: .center,
                startRadius: 60, endRadius: 620
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            LinearGradient(
                stops: [.init(color: .clear, location: 0.6), .init(color: .black.opacity(0.75), location: 0.82)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            // Reduce Transparency / Increase Contrast: a solid backdrop over the cover wall.
            LegibilityScrim(opacity: 0.8)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                heading
                    .padding(.top, 54)
                Spacer(minLength: 12)
                SpotlightCard(
                    content: spotlightContent, albums: spotlightAlbums, taste: model.taste, activity: status.activity
                ) {
                    if let song = spotlightSong, !(showsOpener && song.id == opener.track?.id) { OpenerButton(track: song) }
                }
                Spacer(minLength: 12)
                VStack(spacing: 14) {
                    if !portraits.isEmpty {
                        SignedTicker(artists: portraits, spotlight: $spotlight)
                    }
                    if !upcoming.isEmpty {
                        RosterMarquee(artists: upcoming)
                            .frame(maxWidth: 820)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.bottom, 20)
                footer
                    .padding(.bottom, 26)
            }
            .padding(.horizontal, 40)
        }
        .immersiveChrome()
        .debugSnapshots("building")
        .observing(model.services.db) { db in
            let artists = try Artist.filter(Column("status") != ItemStatus.failed.rawValue)
                .order(Column("createdAt")).fetchAll(db)
            let covers = try Album.filter(sql: "coverPath IS NOT NULL").order(Column("createdAt")).fetchAll(db)
            let recorded = try Track.filter(Column("status") == TrackStatus.ready.rawValue).fetchAll(db)
            return Snapshot(artists: artists, covers: covers, recorded: recorded)
        } update: { snapshot in
            receive(snapshot)
        }
        .observing(model.services.db, id: "opener") { db in
            let song = try OpenerSong.fetch(db)
            let others = try GenerationBatch.filter(Column("kind") != BatchKind.initialLibrary.rawValue).fetchCount(db)
            return OpenerObservation(song: song, firstLibrary: others == 0)
        } update: { value in
            withAnimation(.smooth(duration: 0.6)) {
                opener = value.song
                firstLibrary = value.firstLibrary
            }
        }
        .task(id: "\(portraitOrder.count)-\(artists.count)") {
            // Between arrivals, rotate the spotlight: through portraits once there are some, otherwise through
            // the freshly cast roster so the names themselves are the show.
            while !Task.isCancelled {
                let onRoster = portraitOrder.isEmpty
                try? await Task.sleep(for: .seconds(onRoster ? 4 : 7))
                guard !Task.isCancelled else { return }
                let pool = onRoster ? upcoming.map(\.id) : portraitOrder
                guard pool.count > 1 else { continue }
                let current = spotlight.flatMap { pool.firstIndex(of: $0) } ?? -1
                let next = onRoster ? (current + 1) % pool.count : (current + pool.count - 1) % pool.count
                withAnimation(.smooth(duration: 0.7)) { spotlight = pool[next] }
            }
        }
    }

    private struct OpenerObservation: Equatable, Sendable {
        var song: OpenerSong
        var firstLibrary: Bool
    }

    private var openerStage: WhileYouWaitCard.Stage {
        let installed = if case .installed = model.modelState { true } else { false }
        return WhileYouWaitCard.stage(for: opener, recording: model.recording, modelInstalled: installed)
    }

    /// The "while you wait" player: from the moment the build starts until the song is recorded and
    /// beyond. If it couldn't be made, the studio line (and the spotlight's play button) take over.
    private var showsOpener: Bool {
        guard openerStage != .failed, status.phase != .failed else { return false }
        if opener.state?.artistID != nil { return true }
        // Before the roster lands: a placeholder for the song that's on its way.
        return opener.state == nil && firstLibrary && recorded.isEmpty
            && (status.phase == .planning || status.phase == .idle || status.phase == .writing && artists.isEmpty)
    }

    private var status: BuildStatus { model.buildStatus }
    private var readyCount: Int { max(status.artistsReady, artists.count { $0.status == .ready }) }
    private var totalCount: Int {
        if status.artistsTotal > 0 { return max(status.artistsTotal, readyCount) }
        return artists.isEmpty ? 110 : artists.count
    }
    /// Finished work in artists, including partly written ones, so the bar moves from the first minute.
    private var progressValue: Double { min(Double(totalCount), max(Double(readyCount), status.progress)) }
    private var inProgressCount: Int { status.phase == .finished ? 0 : status.artistsInProgress }
    private var canListen: Bool { readyCount >= Self.readyThreshold || status.phase == .finished }
    private var portraits: [Artist] { portraitOrder.compactMap { id in artists.first { $0.id == id } } }
    /// Cast but not yet photographed.
    private var upcoming: [Artist] { artists.filter { $0.imagePath == nil } }
    private var spotlightAlbums: [Album] {
        coverOrder.compactMap { covers[$0] }.filter { $0.artistID == spotlight }.sorted { $0.releaseYear < $1.releaseYear }
    }

    /// The spotlight artist's earliest recorded song, playable right here.
    private var spotlightSong: Track? {
        recorded.filter { $0.artistID == spotlight }.min { ($0.discNumber, $0.trackNumber) < ($1.discNumber, $1.trackNumber) }
    }

    private var spotlightContent: SpotlightContent {
        if let artist = artists.first(where: { $0.id == spotlight }) {
            return artist.imagePath == nil ? .cast(artist) : .portrait(artist)
        }
        if let first = upcoming.first { return .cast(first) }
        return .brief
    }

    private func receive(_ snapshot: Snapshot) {
        let knownPortraits = Set(portraitOrder)
        let freshPortraits = snapshot.artists.filter { $0.imagePath != nil && !knownPortraits.contains($0.id) }.map(\.id)
        let knownCovers = Set(coverOrder)
        let freshCovers = snapshot.covers.map(\.id).filter { !knownCovers.contains($0) }
        withAnimation(.smooth(duration: 0.8)) {
            artists = snapshot.artists
            recorded = snapshot.recorded
            covers = Dictionary(snapshot.covers.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            coverOrder.append(contentsOf: freshCovers)
            portraitOrder.append(contentsOf: freshPortraits)
            if let newest = freshPortraits.last {
                spotlight = newest
            } else if spotlight == nil || !artists.contains(where: { $0.id == spotlight }) {
                spotlight = portraitOrder.last ?? upcoming.first?.id
            }
        }
    }

    // MARK: Pieces

    private var heading: some View {
        VStack(spacing: 8) {
            Text(status.phase == .finished ? "Your library is ready" : "Building your library")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .contentTransition(.opacity)
                .accessibilityHeading()
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.62))
                .contentTransition(.opacity)
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .animation(.smooth, value: subtitle)
    }

    private var subtitle: String {
        if status.phase == .finished { return "\(readyCount) artists, all invented for you." }
        if status.phase == .failed { return "Something interrupted the studio." }
        if artists.isEmpty { return "Casting artists who’ve never existed — just for you." }
        if portraitOrder.isEmpty { return "\(artists.count) artists cast. Now writing their stories and shooting portraits…" }
        return "Every artist, album and cover is being made just for you."
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 18) {
            if status.phase == .failed {
                failure
            } else {
                progress
            }
            HStack(alignment: .center) {
                if showsOpener {
                    VStack(alignment: .leading, spacing: 10) {
                        WhileYouWaitCard(song: opener, genre: opener.state?.genre ?? Opener.favoriteGenre(model.taste))
                        // Once the opener is in hand, the studio line goes back to reporting the rest.
                        if openerStage == .ready { StudioLine(recordedCount: recorded.count) }
                    }
                    .transition(.blurReplace)
                } else {
                    StudioLine(recordedCount: recorded.count)
                }
                Spacer()
                listenButton
            }
            .frame(maxWidth: 820)
        }
    }

    private var progress: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(readyCount) of \(totalCount) artists ready")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(readyCount)))
                if inProgressCount > 0 {
                    Text("· \(inProgressCount) in the works")
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .contentTransition(.numericText(value: Double(inProgressCount)))
                }
                if !portraitOrder.isEmpty || !coverOrder.isEmpty {
                    Text("· \(portraitOrder.count) portraits · \(coverOrder.count) covers")
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                        .contentTransition(.numericText())
                }
                Spacer()
                activityLine
            }
            GeometryReader { geo in
                let fraction = totalCount > 0 ? progressValue / Double(totalCount) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [.pink, .orange.opacity(0.9)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, geo.size.width * fraction))
                        .shadow(color: .pink.opacity(0.6), radius: 6)
                }
            }
            .frame(height: 6)
            .animation(.smooth(duration: 0.8), value: progressValue)
            .accessibilityElement()
            .accessibilityLabel("Library progress")
            .accessibilityValue("\(readyCount) of \(totalCount) artists ready, \(inProgressCount) in the works")
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 820)
    }

    @ViewBuilder
    private var activityLine: some View {
        if status.phase == .waiting, let until = status.waitingUntil {
            Label {
                Text("ChatGPT asked us to slow down — resuming \(until, style: .relative)")
            } icon: {
                Image(systemName: "hourglass").accessibilityHidden(true)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.6))
        } else if !status.activity.isEmpty {
            Text(status.activity)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
                .animation(.smooth, value: status.activity)
        }
    }

    private var failure: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 20))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Library building paused")
                    .font(.system(size: 14, weight: .semibold))
                Text(status.error ?? "Something went wrong.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                retrying = true
                Task {
                    try? await model.services.builder.resumeUnfinished()
                    retrying = false
                }
            } label: {
                if retrying { ProgressView().controlSize(.small) } else { Text("Try Again").foregroundStyle(.white) }
            }
            .buttonStyle(.glass)
            .disabled(retrying)
            .accessibilityLabel(retrying ? "Trying again" : "Try Again")
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: 820)
        .glassEffect(.regular.tint(.red.opacity(0.25)), in: .rect(cornerRadius: 16))
        .transition(.blurReplace)
    }

    @ViewBuilder
    private var listenButton: some View {
        if canListen {
            VStack(alignment: .trailing, spacing: 6) {
                Button("Start Listening") { model.enterLibrary() }
                    .buttonStyle(.onboardingPrimary)
                    .keyboardShortcut(.defaultAction)
                if status.phase != .finished {
                    Text("Your library keeps growing in the background.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                Button { model.enterLibrary() } label: { Text("Start Listening").foregroundStyle(.white.opacity(readyCount == 0 ? 0.5 : 1)) }
                    .buttonStyle(.glass)
                    .disabled(readyCount == 0)
                Text(
                    readyCount == 0
                        ? "Available once your first artists sign."
                        : "Best after \(Self.readyThreshold) artists — \(Self.readyThreshold - readyCount) to go."
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Cover wall

/// A wall of album covers that fills in scattered order as new covers arrive.
private struct CoverWall: View {
    let albums: [Album]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tile: CGFloat = 132
    private let gap: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let columns = Int(geo.size.width / (tile + gap)) + 2
            let rows = Int(geo.size.height / (tile + gap)) + 2
            let count = columns * rows
            let order = Self.scatter(count)
            // Once the wall is full, each new cover replaces one tile instead of reshuffling the rest.
            let assigned = Dictionary(albums.enumerated().map { (order[$0.offset % count], $0.element) }, uniquingKeysWith: { _, new in new })
            VStack(spacing: gap) {
                ForEach(0 ..< rows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0 ..< columns, id: \.self) { c in
                            let slot = r * columns + c
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.white.opacity(0.035))
                                if let album = assigned[slot] {
                                    ArtworkView(source: .album(album), size: tile, cornerRadius: 8, shadow: false)
                                        .id(album.id)
                                        // Reduce Motion: covers fade in instead of flying in.
                                        .transition(
                                            .asymmetric(
                                                insertion: reduceMotion ? .opacity : .scale(scale: 1.7).combined(with: .opacity),
                                                removal: .opacity))
                                }
                            }
                            .frame(width: tile, height: tile)
                        }
                    }
                    .offset(x: r.isMultiple(of: 2) ? 0 : -(tile + gap) / 2)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .opacity(0.55)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A stable pseudo-random fill order.
    static func scatter(_ count: Int) -> [Int] {
        var generator = WallRandom(seed: UInt64(count))
        return Array(0 ..< count).shuffled(using: &generator)
    }
}

private struct WallRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Spotlight

private enum SpotlightContent: Equatable {
        /// Before the roster exists: what we're casting for.
        case brief
        /// Named and described, portrait still being shot.
        case cast(Artist)
        case portrait(Artist)
}

private struct SpotlightCard<Accessory: View>: View {
    typealias Content = SpotlightContent

    let content: Content
    let albums: [Album]
    let taste: TasteProfile
    let activity: String
    @ViewBuilder var accessory: Accessory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var key: String {
        switch content {
        case .brief: "brief"
        case .cast(let a): "cast-\(a.id)"
        case .portrait(let a): "portrait-\(a.id)"
        }
    }

    var body: some View {
        ZStack {
            switch content {
            case .brief: brief
            case .cast(let artist): card(artist, portrait: false)
            case .portrait(let artist): card(artist, portrait: true)
            }
        }
        .id(key)
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .scale(scale: 0.94).combined(with: .opacity).combined(with: .offset(y: 14)),
                    removal: .opacity.combined(with: .scale(scale: 1.03))))
        .foregroundStyle(.white)
        .padding(30)
        .frame(minHeight: 270)
    }

    private func card(_ artist: Artist, portrait: Bool) -> some View {
        HStack(spacing: 34) {
            Group {
                if portrait {
                    ArtworkView(source: .artist(artist), size: 210, circular: true, highResolution: true,
                                accessibilityDescription: "Portrait of \(artist.name)")
                } else {
                    Monogram(artist: artist)
                }
            }
            .shadow(color: (Color(hex: artist.accentHex) ?? .pink).opacity(portrait ? 0.55 : 0.25), radius: 40)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(label(artist, portrait: portrait))
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(.pink)
                    Text(artist.name)
                        .font(.system(size: 38, weight: .bold))
                        .tracking(-0.8)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text(details(artist))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    if !artist.tagline.isEmpty {
                        Text(artist.tagline)
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(3)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenCard(artist, portrait: portrait))
                .accessibilityAddTraits(.isHeader)
                HStack(spacing: 10) {
                    TierChip(tier: artist.tier)
                    if portrait { discography(artist) }
                }
                .padding(.top, 6)
                if portrait { accessory }
            }
            .frame(maxWidth: 440, alignment: .leading)
        }
    }

    private func spokenCard(_ artist: Artist, portrait: Bool) -> String {
        let state = artist.status == .ready ? "Just signed" : portrait ? "Signing now" : "On the roster"
        return [state, artist.name, details(artist).replacingOccurrences(of: " · ", with: ", "), artist.tagline]
            .filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private func label(_ artist: Artist, portrait: Bool) -> String {
        if artist.status == .ready { return "JUST SIGNED" }
        return portrait ? "SIGNING NOW" : "ON THE ROSTER"
    }

    /// Covers that exist, then shimmering slots for the ones still being painted.
    private func discography(_ artist: Artist) -> some View {
        let pending = artist.status == .ready ? 0 : max(0, min(artist.plannedAlbumCount, 6) - albums.count)
        return HStack(spacing: 8) {
            ForEach(albums.prefix(6)) { album in
                ArtworkView(source: .album(album), size: 46, cornerRadius: 5,
                            accessibilityDescription: Spoken.albumCover(album.title, by: artist.name) + ", \(album.releaseYear)")
                    .help("\(album.title) (\(String(album.releaseYear)))")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            ForEach(0 ..< pending, id: \.self) { _ in
                ShimmerBlock(cornerRadius: 5)
                    .frame(width: 46, height: 46)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .overlay(Image(systemName: "paintbrush.pointed.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.3)))
                    .help("Cover art in progress")
                    .accessibilityLabel("Cover art in progress")
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.3), value: albums.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Discography")
    }

    private var brief: some View {
        HStack(spacing: 34) {
            ZStack {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0 ..< 3, id: \.self) { ring in
                            let phase = (t / 2.8 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .stroke(Color.pink.opacity(0.5 * (1 - phase)), lineWidth: 1.5)
                                .frame(width: 120 + 110 * phase, height: 120 + 110 * phase)
                        }
                    }
                }
                Image(systemName: "person.3.sequence.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                    .frame(width: 120, height: 120)
                    .background(Circle().fill(LinearGradient(colors: [.pink, Color(hue: 0.98, saturation: 0.8, brightness: 0.55)], startPoint: .top, endPoint: .bottom)))
            }
            .frame(width: 230, height: 230)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                Text("CASTING")
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(.pink)
                    .accessibilityLabel("Casting")
                Text(taste.headline.isEmpty ? "Dreaming up your roster" : taste.headline)
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.5)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .accessibilityHeading()
                let genres = Array((taste.coreGenres.isEmpty ? taste.selectedGenres : taste.coreGenres).prefix(4))
                if !genres.isEmpty {
                    CenteredFlowLayout(spacing: 6) {
                        ForEach(genres, id: \.self) { genre in
                            Text(genre.capitalized(with: .current))
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(.white.opacity(0.12)))
                        }
                    }
                    .fixedSize()
                }
                Text(activity.isEmpty ? "Inventing artists who’ve never existed. Their names arrive in under a minute." : activity)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
            .frame(maxWidth: 440, alignment: .leading)
        }
    }

    private func details(_ artist: Artist) -> String {
        var parts = [artist.primaryGenre]
        if !artist.origin.isEmpty { parts.append(artist.origin) }
        if artist.formedYear > 0 { parts.append("Since \(String(artist.formedYear))") }
        return parts.joined(separator: " · ")
    }
}

/// Stand-in portrait while the photo shoot is still happening: initials on the artist's colors.
private struct Monogram: View {
    let artist: Artist
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colors = Color(hex: artist.accentHex).map { [$0, $0.opacity(0.5)] } ?? ArtworkView.seeded(artist.id)
        ZStack {
            Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initials)
                .font(.system(size: 64, weight: .bold, design: .serif))
                .foregroundStyle(.white.opacity(0.9))
            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .padding(-8)
                .rotationEffect(.degrees(spin && !reduceMotion ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 2.4).repeatForever(autoreverses: false), value: spin)
        }
        .frame(width: 210, height: 210)
        .overlay(alignment: .bottom) {
            Label("Portrait in progress", systemImage: "camera.fill")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.45)))
                .offset(y: 14)
        }
        .onAppear { spin = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Portrait of \(artist.name) in progress")
    }

    @State private var spin = false

    private var initials: String {
        let words = artist.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

private struct TierChip: View {
    let tier: TasteTier

    var body: some View {
        let (text, icon): (String, String) =
            switch tier {
            case .core: ("Right up your street", "heart.fill")
            case .adjacent: ("Next door to your taste", "arrow.triangle.branch")
            case .wildcard: ("A wildcard", "sparkle")
            }
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(0.1)))
    }
}

/// The cast-but-not-yet-photographed roster, drifting past like a signing sheet.
private struct RosterMarquee: View {
    let artists: [Artist]
    @State private var rowWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("UP NEXT")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(.pink)
                Text("\(artists.count) on the roster")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .contentTransition(.numericText(value: Double(artists.count)))
            }
            .fixedSize()
            GeometryReader { _ in
                // Reduce Motion: the roster stays put (scrollable names would be overkill here).
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let offset = rowWidth > 0 ? CGFloat((t * 26).truncatingRemainder(dividingBy: Double(rowWidth))) : 0
                    HStack(spacing: 0) {
                        row.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
                        row
                    }
                    .fixedSize()
                    .offset(x: -offset)
                }
            }
            .frame(height: 20)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                    startPoint: .leading, endPoint: .trailing))
        }
        .accessibilityElement()
        .accessibilityLabel("Up next: \(artists.prefix(10).map(\.name).joined(separator: ", "))")
    }

    private var row: some View {
        HStack(spacing: 0) {
            ForEach(artists.prefix(40)) { artist in
                HStack(spacing: 6) {
                    Text(artist.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                    Text(artist.primaryGenre).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.45))
                }
                Text("✦").font(.system(size: 8)).foregroundStyle(.pink.opacity(0.7)).padding(.horizontal, 14)
            }
        }
    }
}


/// The most recent signings; clicking one brings it into the spotlight.
private struct SignedTicker: View {
    let artists: [Artist]
    @Binding var spotlight: ID?

    var body: some View {
        HStack(spacing: 12) {
            ForEach(artists.suffix(12).reversed()) { artist in
                Button {
                    withAnimation(.smooth(duration: 0.6)) { spotlight = artist.id }
                } label: {
                    ArtworkView(source: .artist(artist), size: spotlight == artist.id ? 44 : 36, circular: true)
                        .overlay(Circle().strokeBorder(spotlight == artist.id ? Color.pink : .clear, lineWidth: 2))
                        .opacity(spotlight == artist.id ? 1 : 0.75)
                }
                .buttonStyle(.plain)
                .help(artist.name)
                .accessibilityLabel(artist.name)
                .accessibilityHint("Shows this artist in the spotlight")
                .accessibilityAddTraits(spotlight == artist.id ? .isSelected : [])
                .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(height: 48)
        .animation(.spring(duration: 0.5, bounce: 0.35), value: artists.map(\.id))
        .animation(.smooth, value: spotlight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recently signed")
    }
}

// MARK: - Studio

/// Secondary status line for the music model download.
private struct StudioDownloadStatus: View {
    let state: AppModel.ModelState
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch state {
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                Text("Recording studio ready")
            case .downloading(let p):
                RecordingRing(fraction: p.fraction, lineWidth: 2, tint: .white.opacity(0.8))
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Setting up the recording studio")
                    Text(detail(p))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Setting up the recording studio")
                .accessibilityValue("Downloading, \(Spoken.percent(p.fraction)), \(detail(p))")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).accessibilityHidden(true)
                Text("Studio download failed").help(message).accessibilityValue(message)
                Button(action: retry) { Text("Retry").foregroundStyle(.white) }.buttonStyle(.glass).controlSize(.small)
            case .unknown:
                ProgressView().controlSize(.mini)
                Text("Checking the recording studio…")
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.7))
        .animation(.smooth, value: state)
    }

    private func detail(_ p: ModelDownloadProgress) -> String {
        guard p.totalBytes > 0 else { return "Starting download…" }
        let bytes = ByteCountFormatStyle(style: .file)
        var text = "\(p.receivedBytes.formatted(bytes)) of \(p.totalBytes.formatted(bytes))"
        if p.bytesPerSecond > 0 {
            text += " · \(Int64(p.bytesPerSecond).formatted(bytes))/s"
            let left = Double(p.totalBytes - p.receivedBytes) / p.bytesPerSecond
            if left > 60 { text += " · " + (Format.remaining(left) ?? "") }
        }
        return text
    }
}

/// Plays (or pauses) a song recorded during the build, right from the building screen.
private struct OpenerButton: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        let player = model.player
        let isCurrent = player.current?.track.id == track.id
        Button {
            if isCurrent { player.togglePlayPause() } else { player.play(albumID: track.albumID, startingAt: track.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                Text(isCurrent && player.isPlaying ? "Playing “\(track.title)”" : "Play “\(track.title)”")
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Fresh from the studio")
        .padding(.top, 4)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// What the studio is doing: downloading the model, recording an opener, or idle with songs ready.
private struct StudioLine: View {
    @Environment(AppModel.self) private var model
    let recordedCount: Int

    var body: some View {
        Group {
            if case .installed = model.modelState, let active = model.recording.active {
                HStack(spacing: 10) {
                    RecordingRing(fraction: active.fraction, lineWidth: 2, tint: .pink)
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("In the studio: “\(active.title)” by \(active.artistName)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(detail(active))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.45))
                            .contentTransition(.numericText())
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("In the studio: “\(active.title)” by \(active.artistName)")
                .accessibilityValue(Spoken.recording(fraction: active.fraction, stage: active.stageLabel, remaining: active.remaining)
                    + (recordedCount > 0 ? ", \(recordedCount) recorded" : ""))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: 440, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    StudioDownloadStatus(state: model.modelState) { model.installModelIfNeeded() }
                    if recordedCount > 0, case .installed = model.modelState {
                        Text("· \(recordedCount) song\(recordedCount == 1 ? "" : "s") recorded")
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .animation(.smooth, value: model.recording.active?.trackID)
    }

    private func detail(_ active: RecordingQueue.Activity) -> String {
        var parts = [active.stageLabel]
        if active.fraction > 0.005 { parts.append(active.fraction.formatted(.percent.precision(.fractionLength(0)))) }
        if let left = Format.remaining(active.remaining) { parts.append(left) }
        if recordedCount > 0 { parts.append("\(recordedCount) recorded") }
        return parts.joined(separator: " · ")
    }
}

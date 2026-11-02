import StandardKit
import SwiftUI

/// State for the onboarding questionnaire. Everything the listener tells us is kept so Back can
/// restore it, and the taste profile is derived from it on demand.
@MainActor
@Observable
final class OnboardingFlow {
    enum Step: Hashable {
        case genres, artists, question(Int), notes, tuning, reveal
    }

    struct RecordedAnswer {
        var answer: TasteAnswer
        var liked: [CatalogArtist] = []
        var disliked: [CatalogArtist] = []
        /// What was picked, so the question can show it again after Back.
        var selection: Set<Int64> = []
        var spectrum: Double?
    }

    static let questionCount = 4
    static let minimumArtists = 3

    let catalog: Catalog?
    let engine: TasteEngine?

    private(set) var step: Step = .genres
    private(set) var forward = true

    var genres: [CatalogGenre] = []
    var genresLoaded = false
    var selectedGenres: [String] = []

    var cloud: [CatalogArtist] = []
    var liked: [CatalogArtist] = []
    /// Artists added because a selection spawned them; used for the pop-in animation.
    var spawned: Set<Int64> = []

    private(set) var questions: [Int: TasteQuestion] = [:]
    private var questionTasks: [Int: Task<Void, Never>] = [:]
    private var firstQuestionKey = ""
    var answers: [Int: RecordedAnswer] = [:]

    var notes = ""
    var refined: TasteProfile?
    var finishError: String?

    weak var autopilotModel: AppModel?

    init(model: AppModel) {
        autopilotModel = model
        catalog = model.services.catalog
        engine = catalog.map { TasteEngine(client: model.services.client, catalog: $0) }
    }

    // MARK: Navigation

    static let steps: [Step] =
        [.genres, .artists] + (0 ..< questionCount).map { .question($0) } + [.notes, .tuning, .reveal]

    var progress: Double {
        let index = Self.steps.firstIndex(of: step) ?? 0
        return Double(index) / Double(Self.steps.count - 2)
    }

    var canGoBack: Bool {
        switch step {
        case .genres, .tuning, .reveal: false
        default: true
        }
    }

    func go(to next: Step) {
        let from = Self.steps.firstIndex(of: step) ?? 0
        let to = Self.steps.firstIndex(of: next) ?? 0
        forward = to >= from
        withAnimation(.smooth(duration: 0.5)) { step = next }
        if case .question(let i) = next {
            ensureQuestion(i)
            ensureQuestion(i + 1)
        }
        if next == .artists, cloud.isEmpty { loadCloud() }
    }

    func back() {
        guard canGoBack, let index = Self.steps.firstIndex(of: step), index > 0 else { return }
        go(to: Self.steps[index - 1])
    }

    func advance() {
        guard let index = Self.steps.firstIndex(of: step), index + 1 < Self.steps.count else { return }
        go(to: Self.steps[index + 1])
    }

    // MARK: Genres

    func loadGenres() async {
        guard !genresLoaded else { return }
        guard let catalog else {
            genresLoaded = true
            return
        }
        let loaded = await Task.detached(priority: .userInitiated) { Self.genreTiles(catalog) }.value
        withAnimation(.smooth) {
            genres = loaded
            genresLoaded = true
        }
    }

    nonisolated static let styles = [
        "Indie Rock", "Indie Pop", "Techno/House", "Soul & Funk", "Folk", "K-Pop", "Hard Rock", "Blues",
        "Singer & Songwriter", "Reggaeton", "Disco", "Afro Pop", "Chill Out/Trip-Hop/Lounge", "Dancehall/Ragga",
        "Trance", "Dubstep", "Gospel",
    ]
    /// Shown last: niche or not really a taste of their own.
    nonisolated static let tail = ["Films/Games", "Christian", "Gospel"]

    /// Coarse catalog genres plus style-level buckets, each with four portraits not used by an earlier tile.
    nonisolated static func genreTiles(_ catalog: Catalog) -> [CatalogGenre] {
        let primary = (try? catalog.genres(minimumArtists: 40)) ?? []
        let styled = (try? catalog.styleGenres(styles, minimumArtists: 25, featured: 16)) ?? []
        let styleNames = Set(styled.map(\.name))
        var tiles = Array(primary.filter { !styleNames.contains($0.name) && !tail.contains($0.name) }.prefix(14))
        tiles += styled.filter { !tail.contains($0.name) }
        tiles += (primary + styled).filter { tail.contains($0.name) }
        var used = Set<Int64>()
        for i in tiles.indices {
            var pool = tiles[i].featured
            if pool.count < 12, let more = try? catalog.topArtists(genres: [tiles[i].name], perGenre: 16) { pool += more }
            var picked: [CatalogArtist] = []
            for artist in pool where picked.count < 4 && artist.pictureSmallURL != nil && used.insert(artist.id).inserted {
                picked.append(artist)
            }
            tiles[i].featured = picked.count == 4 ? picked : Array(tiles[i].featured.prefix(4))
        }
        return tiles
    }

    func toggle(genre: String) {
        if let i = selectedGenres.firstIndex(of: genre) {
            selectedGenres.remove(at: i)
        } else {
            selectedGenres.append(genre)
        }
        // A different genre mix deserves a fresh cloud (keeping anything already picked).
        if !cloud.isEmpty { cloudIsStale = true }
    }

    private var cloudIsStale = false

    // MARK: Artists

    func refreshCloudIfNeeded() {
        guard cloudIsStale else { return }
        cloudIsStale = false
        loadCloud()
    }

    func loadCloud() {
        guard let catalog else { return }
        let genres = selectedGenres
        let keep = liked
        Task {
            let perGenre = max(5, 40 / max(genres.count, 1))
            let excluding = Set(keep.map(\.id))
            let top = await Task.detached(priority: .userInitiated) {
                (try? catalog.topArtists(genres: genres, perGenre: perGenre, excluding: excluding)) ?? []
            }.value
            withAnimation(.smooth(duration: 0.6)) {
                cloud = keep + top.prefix(48)
            }
        }
    }

    func isLiked(_ artist: CatalogArtist) -> Bool { liked.contains { $0.id == artist.id } }

    func toggle(artist: CatalogArtist) {
        if let i = liked.firstIndex(where: { $0.id == artist.id }) {
            withAnimation(.spring(duration: 0.4, bounce: 0.35)) { _ = liked.remove(at: i) }
            return
        }
        withAnimation(.spring(duration: 0.45, bounce: 0.45)) {
            liked.append(artist)
            if !cloud.contains(where: { $0.id == artist.id }) { cloud.insert(artist, at: 0) }
        }
        invalidateFirstQuestionIfNeeded()
        guard let catalog else { return }
        let id = artist.id
        Task {
            let related = await Task.detached(priority: .userInitiated) { (try? catalog.related(to: id, limit: 10)) ?? [] }.value
            let present = Set(cloud.map(\.id))
            let fresh = related.filter { !present.contains($0.id) }.prefix(3)
            guard !fresh.isEmpty, let at = cloud.firstIndex(where: { $0.id == id }) else { return }
            withAnimation(.spring(duration: 0.55, bounce: 0.3)) {
                spawned.formUnion(fresh.map(\.id))
                cloud.insert(contentsOf: fresh, at: at + 1)
            }
        }
    }

    func search(_ text: String) async -> [CatalogArtist] {
        guard let catalog, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { (try? catalog.search(text, limit: 12)) ?? [] }.value
    }

    // MARK: Questions

    /// The profile so far, counting only answers to questions before `index`.
    func profile(before index: Int = .max) -> TasteProfile {
        var p = TasteProfile()
        p.selectedGenres = selectedGenres
        let recorded = answers.filter { $0.key < index }.sorted { $0.key < $1.key }.map(\.value)
        var seen = Set<Int64>()
        let likedAll = (liked + recorded.flatMap(\.liked)).filter { seen.insert($0.id).inserted }
        let dislikedAll = recorded.flatMap(\.disliked).filter { seen.insert($0.id).inserted }
        p.likedArtists = likedAll.map(SeedArtist.init)
        p.dislikedArtists = dislikedAll.map(SeedArtist.init)
        p.answers = recorded.map(\.answer)
        p.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return p
    }

    private var likedKey: String { liked.map { String($0.id) }.sorted().joined(separator: ",") }

    /// Prefetch the first question once the listener has picked enough artists.
    func prefetchFirstQuestion() {
        guard liked.count >= Self.minimumArtists else { return }
        ensureQuestion(0)
    }

    private func invalidateFirstQuestionIfNeeded() {
        guard !firstQuestionKey.isEmpty, firstQuestionKey != likedKey, answers.isEmpty else { return }
        for (_, task) in questionTasks { task.cancel() }
        questionTasks = [:]
        questions = [:]
        firstQuestionKey = ""
    }

    func ensureQuestion(_ index: Int) {
        guard let engine, index < Self.questionCount, questions[index] == nil, questionTasks[index] == nil else { return }
        if index == 0 { firstQuestionKey = likedKey }
        let profile = profile(before: index)
        let asked = (0 ..< index).compactMap { questions[$0] }
        let remaining = Self.questionCount - index - 1
        questionTasks[index] = Task {
            let question = await engine.nextQuestion(profile: profile, asked: asked, remaining: remaining)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.4)) { questions[index] = question }
            questionTasks[index] = nil
        }
    }

    func record(_ answer: RecordedAnswer, for index: Int) {
        answers[index] = answer
        advance()
    }

    // MARK: Finish

    func finish(using model: AppModel) async {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["SM_ONBOARDING_AUTOPILOT"], mode != "full" { return }
        #endif
        finishError = nil
        let started = Date()
        do {
            let result = try await model.finishOnboarding(profile())
            // Let the moment breathe even when refinement is quick.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 3.5 { try? await Task.sleep(for: .seconds(3.5 - elapsed)) }
            refined = result
            go(to: .reveal)
        } catch {
            withAnimation(.smooth) { finishError = error.localizedDescription }
        }
    }
}

import AppKit
import StandardKit
import SwiftUI

struct StudioSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.quality) private var quality = GenerationQuality.balanced
    @AppStorage(Pref.lookahead) private var lookahead = 2
    @AppStorage(Pref.engineIdleMinutes) private var idleMinutes = 5
    @AppStorage(Pref.backgroundRecording) private var backgroundRecording = false
    @AppStorage(Pref.modelVariant) private var variantRaw = ModelVariant.recommended.rawValue
    @State private var recordingsSize: Int64?
    @State private var recordingsCount = 0
    @State private var downloads: [ModelVariant: ModelDownloadProgress] = [:]
    @State private var modelError: String?
    @State private var diskGeneration = 0
    @State private var showsGuide = false
    @AppStorage(Pref.engineKind) private var engineKind = EngineKind.builtIn

    var body: some View {
        SettingsPane(height: 640) {
            Section {
                Picker("Quality", selection: $quality) {
                    ForEach(GenerationQuality.allCases) { q in
                        Text(q.title).tag(q)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent {
                    Text(estimate(for: quality)).monospacedDigit()
                } label: {
                    Text(Self.detail(quality))
                    Text(hasMeasurements ? "Estimated from songs recorded on this Mac." : "A rough estimate until your first song is recorded.")
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("Applies to songs recorded from now on. Songs you already have keep their sound.")
                    .settingsFooter()
            }

            Section {
                Picker(selection: $lookahead) {
                    ForEach(1 ... 4, id: \.self) { n in
                        Text(n == 1 ? "1 song" : "\(n) songs").tag(n)
                    }
                } label: {
                    Text("Record ahead")
                    Text("While you listen, the studio works on what’s coming up next.")
                }
                .onChange(of: lookahead) { _, _ in model.player.refreshDemand() }
                Toggle(isOn: $backgroundRecording) {
                    Text("Record in the background")
                    Text("When the studio is free, it records the first song of albums you’re likely to play — favourites and your core taste — so Play starts instantly. Uses the GPU and more battery.")
                }
                .onChange(of: backgroundRecording) { _, _ in model.recording.kick() }
            }

            Section {
                EnginePicker(showsGuide: $showsGuide)
            } header: {
                Text("Music engine")
            }

            if engineKind == .builtIn {
                Section("YuE2 model") {
                    ForEach(ModelVariant.allCases, id: \.self) { variant in
                        modelRow(variant)
                    }
                    .id(diskGeneration)
                    if let modelError {
                        Text(modelError).foregroundStyle(.red).font(.callout)
                    }
                }
                Section("YuE2 options") {
                    YuEAdvancedOptions()
                }
            } else {
                Section {
                    CustomEngineOptions()
                } header: {
                    Text("Your engine")
                } footer: {
                    Text("Quality, record-ahead and everything else on this page still apply. Your engine receives the quality as a step count.")
                        .settingsFooter()
                }
            }

            Section {
                Picker(selection: $idleMinutes) {
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                } label: {
                    Text("Unload the model after")
                    Text("Frees several gigabytes of memory when the studio has been quiet this long.")
                }
                .onChange(of: idleMinutes) { _, minutes in
                    Task { await model.services.engine.setIdleTimeout(.seconds(60 * max(1, minutes))) }
                }
            }

            Section("Recordings") {
                LabeledContent("Space used") {
                    if let recordingsSize {
                        Text("\(recordingsCount) song\(recordingsCount == 1 ? "" : "s") · \(recordingsSize.formatted(.byteCount(style: .file)))")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.audio]) }
                }
            }
        }
        .task(id: model.recording.active?.trackID) { await measureRecordings() }
        .sheet(isPresented: $showsGuide) { EngineGuideSheet() }
    }

    // MARK: Estimates

    private var hasMeasurements: Bool { UserDefaults.standard.object(forKey: "averageSecondsPerSong") != nil }

    /// Recording time is part fixed (writing the score) and part proportional to the quality's steps.
    private static func cost(_ q: GenerationQuality) -> Double { 0.55 + 0.45 * Double(q.steps) / 16 }

    private func estimate(for q: GenerationQuality) -> String {
        let measuredAt = GenerationQuality.current
        let seconds = model.recording.averageSecondsPerSong * Self.cost(q) / Self.cost(measuredAt)
        let minutes = max(1, Int((seconds / 60).rounded()))
        return "≈ \(minutes) min per song"
    }

    private static func detail(_ q: GenerationQuality) -> String {
        switch q {
        case .draft: "Quickest, with a rougher demo-tape finish."
        case .balanced: "Polished songs without the long wait."
        case .studio: "The richest, cleanest mix. Takes noticeably longer."
        }
    }

    // MARK: Model

    @ViewBuilder
    private func modelRow(_ variant: ModelVariant) -> some View {
        let installed = model.services.models.isInstalled(variant)
        let active = activeVariant == variant
        HStack(spacing: 10) {
            Image(systemName: active ? "checkmark.circle.fill" : installed ? "circle" : "arrow.down.circle")
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .font(.system(size: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(variant.displayName)
                    if variant == .recommended {
                        Text("Recommended for this Mac")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                if let progress = downloads[variant] ?? downloadingPreferred(variant) {
                    ProgressView(value: progress.fraction)
                        .controlSize(.small)
                        .accessibilityLabel("Downloading \(variant.displayName)")
                        .accessibilityValue(Spoken.percent(progress.fraction))
                    Text("\(progress.receivedBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(active ? "In use" : installed ? "Downloaded" : "Not downloaded")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if downloads[variant] == nil, downloadingPreferred(variant) == nil {
                if active {
                    EmptyView()
                } else if installed {
                    Button("Use") { use(variant) }
                        .accessibilityLabel("Use \(variant.displayName)")
                    Button("Delete", role: .destructive) { delete(variant) }
                        .help("Remove this model to free up disk space")
                        .accessibilityLabel("Delete \(variant.displayName)")
                } else {
                    Button("Download") { download(variant) }
                        .accessibilityLabel("Download \(variant.displayName)")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var activeVariant: ModelVariant? {
        guard case .installed(let url) = model.modelState else { return nil }
        return ModelVariant.allCases.first { url.lastPathComponent == $0.directoryName }
    }

    private func downloadingPreferred(_ variant: ModelVariant) -> ModelDownloadProgress? {
        guard variant == model.preferredVariant, case .downloading(let p) = model.modelState else { return nil }
        return p
    }

    private func use(_ variant: ModelVariant) {
        variantRaw = variant.rawValue
        model.refreshModelState()
    }

    private func download(_ variant: ModelVariant) {
        modelError = nil
        downloads[variant] = ModelDownloadProgress(receivedBytes: 0, totalBytes: 0, bytesPerSecond: 0)
        Task {
            do {
                _ = try await model.services.models.install(variant) { progress in
                    Task { @MainActor in if downloads[variant] != nil { downloads[variant] = progress } }
                }
                downloads[variant] = nil
                use(variant)
            } catch {
                downloads[variant] = nil
                modelError = error.localizedDescription
            }
        }
    }

    private func delete(_ variant: ModelVariant) {
        Task {
            let dir = await model.services.models.directory(for: variant)
            try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
            model.refreshModelState()
            diskGeneration += 1
        }
    }

    // MARK: Disk

    private func measureRecordings() async {
        let (size, count) = await DiskUsage.measure(Paths.audio, extension: "m4a")
        recordingsSize = size
        recordingsCount = count
    }
}

enum DiskUsage {
    /// Allocated size of everything under `url`, and how many files have `extension`.
    static func measure(_ url: URL, extension ext: String? = nil) async -> (Int64, Int) {
        await Task.detached(priority: .utility) { scan(url, ext) }.value
    }

    private static func scan(_ url: URL, _ ext: String?) -> (Int64, Int) {
        var total: Int64 = 0
        var count = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return (0, 0) }
        for case let file as URL in e {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
            if let ext, file.pathExtension == ext { count += 1 }
        }
        return (total, count)
    }
}

extension Text {
    func settingsFooter() -> some View {
        font(.callout).foregroundStyle(.secondary)
    }
}

import AppKit
import StandardKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Studio › Engine: pick the built-in YuE2 engine or plug in your own.
struct EnginePicker: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.engineKind) private var kind = EngineKind.builtIn
    @Binding var showsGuide: Bool

    var body: some View {
        Picker(selection: $kind) {
            Text("YuE2 (built in)").tag(EngineKind.builtIn)
            Text("Your own engine").tag(EngineKind.custom)
        } label: {
            Text("Engine")
            Text(kind == .builtIn
                ? "Records every song on this Mac with the open YuE2 model."
                : "Records with a program you provide: any model that can speak Standard Music’s engine protocol.")
        }
        .onChange(of: kind) { _, _ in model.refreshModelState() }
        HStack {
            Spacer()
            Button("How to Use Another Model…") { showsGuide = true }
        }
    }
}

/// YuE2 options beyond the quality preset.
struct YuEAdvancedOptions: View {
    @AppStorage(Pref.scorePlanning) private var planning = ScorePlanningPref.full
    @AppStorage(Pref.maxSongMinutes) private var maxMinutes = 5.5

    var body: some View {
        Picker(selection: $planning) {
            ForEach(ScorePlanningPref.allCases) { Text($0.title).tag($0) }
        } label: {
            Text("Score planning")
            Text(planning.detail)
        }
        Picker(selection: $maxMinutes) {
            Text("3 minutes").tag(3.0)
            Text("4 minutes").tag(4.0)
            Text("5½ minutes").tag(5.5)
            Text("7 minutes").tag(7.0)
        } label: {
            Text("Longest song")
            Text("Songs that run past this fade out. Longer songs take longer to record.")
        }
    }
}

/// The custom engine's program, arguments and model, with a live test.
struct CustomEngineOptions: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.customEnginePath) private var path = ""
    @AppStorage(Pref.customEngineArguments) private var arguments = ""
    @AppStorage(Pref.customEngineModel) private var modelSetting = ""
    @State private var test: TestState = .idle

    enum TestState: Equatable {
        case idle, running
        case passed(Double)
        case failed(String)
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField("Program", text: $path, prompt: Text("/path/to/engine"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                Button("Choose…", action: choose)
            }
        } label: {
            Text("Program")
            Text("An executable or script (with a #! line) that speaks the engine protocol.")
        }
        TextField(text: $arguments, prompt: Text("optional")) {
            Text("Arguments")
            Text("Passed on launch, e.g. --quant 8bit")
        }
        TextField(text: $modelSetting, prompt: Text("optional")) {
            Text("Model")
            Text("Sent to your engine when it loads: a folder, a Hugging Face id, anything it understands.")
        }
        HStack(spacing: 10) {
            switch test {
            case .idle:
                if case .failed(let message) = model.modelState {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
            case .running:
                ProgressView().controlSize(.small)
                Text("Starting your engine and loading the model…").foregroundStyle(.secondary).font(.callout)
            case .passed(let seconds):
                Label("Ready. The model loaded in \(seconds.formatted(.number.precision(.fractionLength(1)))) s.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.callout)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Test Engine", action: runTest)
                .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty || test == .running)
        }
        .onChange(of: path) { _, _ in changed() }
        .onChange(of: arguments) { _, _ in changed() }
        .onChange(of: modelSetting) { _, _ in changed() }
    }

    private func changed() {
        test = .idle
        model.refreshModelState()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the program that runs your music model."
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    private func runTest() {
        model.refreshModelState()
        guard let config = CustomEngineConfig.current else { return }
        guard config.isExecutable else {
            test = .failed("That file can’t be run. Make it executable with chmod +x, and give scripts a #! line.")
            return
        }
        test = .running
        Task {
            do {
                await model.services.engine.configure(executable: config.executable, arguments: config.arguments)
                let seconds = try await model.services.engine.probe(modelDirectory: config.modelDirectory)
                test = .passed(seconds)
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Guide

/// In-app documentation for plugging in another music model. The same material, with more
/// detail, lives in docs/custom-engines.md.
struct EngineGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Use another music model").font(.title2.weight(.semibold))
                    Text("Standard Music doesn’t care which model makes the music. Everything else (your artists, albums, lyrics, taste, the player) stays the same; only the recording step changes. To swap the model, give the app a small program, an *engine*, that turns a song description into an audio file.")

                    step(1, "Write the engine", """
                        The engine is any executable: a Python script, a Swift tool, a shell script calling a server. Standard Music launches it when it needs to record, and talks to it over stdin and stdout, one JSON object per line. It can stay running between songs; the app stops it after the studio has been quiet for a while.
                        """)
                    code("""
                        → {"load":{"modelPath":"/path/or/name"}}
                        ← {"ready":{"loadSeconds":4.2}}

                        → {"generate":{"_0":{"id":"…","style":"…","lyrics":"…",
                             "seed":123,"steps":16,"outputPath":"/…/id.m4a", …}}}
                        ← {"progress":{"id":"…","_1":{"stage":"rendering","stageFraction":0.5,
                             "overall":0.5,"elapsed":30}}}
                        ← {"finished":{"_0":{"id":"…","duration":182.4,"loudness":-14,
                             "seconds":95,"truncated":false}}}
                        """)
                    Text("Write the song to `outputPath` as an AAC .m4a file, then send `finished`. If something goes wrong, send `{\"failed\":{\"id\":\"…\",\"message\":\"…\"}}`. If `{\"cancel\":{\"id\":\"…\"}}` arrives, stop that song and send `cancelled`. Log anything you like to stderr: the last line is shown here if the engine crashes. Never print anything else to stdout.")
                        .font(.callout)

                    step(2, "What each song gives you", """
                        style: genre, instruments, mood and the artist’s voice, as comma-separated tags.
                        lyrics: the full lyrics with section tags like [Verse] and [Chorus].
                        seed: use it, so the same song always comes out the same.
                        steps: the listener’s quality setting (8, 16 or 32). Map it to whatever your model has.
                        title, artist, voice, isInstrumental, maxSeconds: extras, if your model wants them separately.
                        """)

                    step(3, "Point Standard Music at it", """
                        Choose “Your own engine”, pick the program, add any arguments, and fill in Model with whatever your engine expects in load (a folder or a model name). Press Test Engine: the app launches it, sends load, and waits for ready.
                        """)

                    step(4, "Start from the example", """
                        tools/engines/minimax_engine.py in the Standard Music source is a complete engine for MiniMax Music 3 running on MLX, in about 200 lines. Copy it and replace the generate function with your model’s.
                        """)

                    Text("Good to know").font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        bullet("Songs you’ve already recorded keep their sound. Only new recordings use the new engine.")
                        bullet("Shared albums note which engine recorded them, so friends know what to expect if they record the rest.")
                        bullet("Your engine runs with your permissions, like any app you install. Only use code you trust.")
                        bullet("Check your model’s licence before sharing what it makes.")
                    }
                    .font(.callout)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Open Full Guide") {
                    if let url = Self.fullGuideURL { NSWorkspace.shared.open(url) }
                }
                .disabled(Self.fullGuideURL == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
    }

    /// The bundled copy of docs/custom-engines.md, if the build included it.
    static var fullGuideURL: URL? { Bundle.main.url(forResource: "custom-engines", withExtension: "md") }

    private func step(_ n: Int, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(n). \(title)").font(.headline)
            Text(body).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

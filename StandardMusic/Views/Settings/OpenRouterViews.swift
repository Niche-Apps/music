import StandardKit
import SwiftUI

/// Loads the public OpenRouter catalog (free, unauthenticated) with an on-disk cache.
@MainActor
@Observable
final class OpenRouterCatalogModel {
    static let shared = OpenRouterCatalogModel()
    private(set) var models: [OpenRouterModel] = OpenRouterCatalog.cached(at: Paths.openRouterCatalog)
    private(set) var isLoading = false
    private(set) var error: String?

    func refresh(force: Bool = false) async {
        guard force || models.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await OpenRouterCatalog.fetch(cache: Paths.openRouterCatalog)
            error = nil
        } catch {
            self.error = "Couldn’t load the OpenRouter model list."
        }
    }
}

/// Search the live catalog (Free Only filter) or type any model slug.
struct OpenRouterModelPicker: View {
    let title: String
    @Binding var selection: String
    var imageOnly = false
    @State private var catalog = OpenRouterCatalogModel.shared
    @State private var search = ""
    @State private var freeOnly = false
    @State private var custom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(selection.isEmpty ? "None" : selection).font(.callout.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack {
                TextField("Search models", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Free only", isOn: $freeOnly).toggleStyle(.checkbox)
                Button {
                    Task { await catalog.refresh(force: true) }
                } label: {
                    if catalog.isLoading { ProgressView().controlSize(.small) } else { Label("Refresh Models", systemImage: "arrow.clockwise") }
                }
                .labelStyle(.iconOnly).help("Refresh Models")
            }
            List(OpenRouterCatalog.filter(catalog.models.filter { imageOnly || $0.outputsText }, search: search, freeOnly: freeOnly, imageOnly: imageOnly).prefix(300)) { m in
                Button { selection = m.id } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.name).lineLimit(1)
                            Text(m.id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if m.isFree {
                            Text("Free").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.green.opacity(0.2))).foregroundStyle(.green)
                        } else if let price = m.priceSummary {
                            Text(price).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let ctx = m.contextLength { Text("\(ctx / 1000)k").font(.caption2).foregroundStyle(.tertiary) }
                        if m.id == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 170)
            HStack {
                TextField("Any model ID, e.g. openrouter/auto or vendor/model:free", text: $custom)
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                    .onSubmit(applyCustom)
                Button("Use", action: applyCustom).disabled(OpenRouterCatalog.normalizedModelID(custom) == nil)
            }
            if let error = catalog.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .task { await catalog.refresh() }
    }

    private func applyCustom() {
        if let id = OpenRouterCatalog.normalizedModelID(custom) { selection = id; custom = "" }
    }
}

/// Settings › Account when OpenRouter is the provider.
struct OpenRouterAccountSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.openRouterWritingModel) private var writingModel = OpenRouterCatalog.defaultModel
    @AppStorage(Pref.openRouterFastModel) private var fastModel = OpenRouterCatalog.defaultModel
    @AppStorage(Pref.openRouterImageModel) private var imageModel = ""
    @State private var keyField = ""
    @State private var status: String?
    @State private var testing = false
    @State private var hasStoredKey = OpenRouterKey.isStored

    var body: some View {
        Section {
            SecureField("OpenRouter API key (sk-or-…)", text: $keyField)
            HStack {
                if hasStoredKey {
                    Label("Key saved in Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                } else if OpenRouterKey.environmentKeyAvailable {
                    Label("Using OPENROUTER_API_KEY from the environment", systemImage: "terminal").foregroundStyle(.secondary)
                } else {
                    Label("No key yet", systemImage: "key").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save") {
                    Task {
                        await model.useOpenRouter(apiKey: keyField, model: nil)
                        keyField = ""; hasStoredKey = OpenRouterKey.isStored
                    }
                }
                .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Clear") { Task { await model.clearOpenRouterKey(); hasStoredKey = false } }
                    .disabled(!hasStoredKey)
                Button("Test Connection") { Task { await test() } }.disabled(testing)
            }
            if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
        } header: {
            Text("OpenRouter")
        } footer: {
            Text("Use any OpenRouter model. Free models cost nothing; paid models bill your OpenRouter credits. The key is stored in your Mac’s Keychain.")
                .settingsFooter()
        }
        Section("Writing model — artists, albums, lyrics") {
            OpenRouterModelPicker(title: "Writing", selection: $writingModel)
        }
        Section("Quick tasks model — small edits, suggestions") {
            OpenRouterModelPicker(title: "Quick tasks", selection: $fastModel)
        }
        Section {
            Picker("Artwork", selection: Binding(
                get: { imageModel.isEmpty ? "procedural" : "model" },
                set: { imageModel = $0 == "procedural" ? "" : (imageModel.isEmpty ? OpenRouterCatalog.suggestedImageModel : imageModel) }
            )) {
                Text("Procedural artwork (free, $0)").tag("procedural")
                Text("OpenRouter image model").tag("model")
            }
            if !imageModel.isEmpty {
                OpenRouterModelPicker(title: "Image model", selection: $imageModel, imageOnly: true)
            }
        } header: {
            Text("Cover art & press photos")
        } footer: {
            Text("If an image model fails or isn’t set, Standard Music draws artwork locally so albums never stall.")
                .settingsFooter()
        }
        .onChange(of: writingModel) { _, _ in Task { await model.configureClient() } }
        .onChange(of: fastModel) { _, _ in Task { await model.configureClient() } }
        .onChange(of: imageModel) { _, _ in Task { await model.configureClient() } }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        guard let key = OpenRouterKey.current else { status = "Add a key first."; return }
        do {
            let label = try await OpenRouterClient(apiKey: key).checkKey()
            status = "Connected" + (label.map { " — \($0)" } ?? "") + "."
        } catch {
            status = error.localizedDescription
        }
    }
}

/// Welcome › Use OpenRouter.
struct OpenRouterSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var chosen = UserDefaults.standard.string(forKey: Pref.openRouterWritingModel) ?? OpenRouterCatalog.defaultModel
    @State private var working = false

    private var hasExistingKey: Bool { OpenRouterKey.current != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use OpenRouter").font(.title2.bold())
            Text("Write artists, albums and lyrics with any model on OpenRouter — including free ones. No ChatGPT account needed.")
                .foregroundStyle(.secondary)
            SecureField(hasExistingKey ? "Using your saved/environment key — paste to replace" : "OpenRouter API key (sk-or-…)", text: $key)
                .textFieldStyle(.roundedBorder)
            OpenRouterModelPicker(title: "Model", selection: $chosen)
            Text("Artwork is drawn locally for free; you can pick an image model later in Settings › Account.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.signInError { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue") {
                    working = true
                    Task {
                        await model.useOpenRouter(apiKey: key, model: chosen)
                        working = false
                        if model.isAIReady { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || (key.trimmingCharacters(in: .whitespaces).isEmpty && !hasExistingKey))
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

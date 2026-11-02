import StandardKit
import SwiftUI

struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.writingModel) private var writingModel = ChatGPTClient.defaultWritingModel
    @AppStorage(Pref.fastModel) private var fastModel = ChatGPTClient.defaultFastModel
    @State private var models: [ChatGPTModel] = []
    @State private var modelsError: String?
    @State private var confirmSignOut = false

    var body: some View {
        SettingsPane(height: 600) {
            if let creds = model.credentials {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(creds.name ?? creds.email ?? "ChatGPT account")
                                .font(.headline)
                            if creds.name != nil, let email = creds.email {
                                Text(email).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let plan = (model.usage.planType ?? creds.planType) {
                            Text("ChatGPT \(plan.capitalized)")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(.tint.opacity(0.15)))
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Artists, albums, lyrics and artwork are written with your ChatGPT subscription. Songs are recorded on this Mac.")
                        .settingsFooter()
                }

                Section("Usage") {
                    UsageMeter(title: "Short-term limit", percent: model.usage.primaryUsedPercent, resetsAt: model.usage.primaryResetsAt)
                    UsageMeter(title: "Weekly limit", percent: model.usage.secondaryUsedPercent, resetsAt: model.usage.secondaryResetsAt)
                }

                Section {
                    modelPicker("Writing", detail: "Artists, albums and lyrics", selection: $writingModel)
                    modelPicker("Quick tasks", detail: "Small edits and suggestions", selection: $fastModel)
                    if let modelsError {
                        Label(modelsError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Models")
                }
                .onChange(of: writingModel) { _, _ in Task { await model.configureClient() } }
                .onChange(of: fastModel) { _, _ in Task { await model.configureClient() } }

                Section {
                    HStack {
                        Spacer()
                        Button("Sign Out…") { confirmSignOut = true }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "Not Signed In", systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Sign in with ChatGPT from the Standard Music window to start building your library."))
                }
            }
        }
        .task { await loadModels() }
        .confirmationDialog("Sign out of ChatGPT?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
        } message: {
            Text("Your library and recordings stay on this Mac. You’ll need to sign in again to create new music.")
        }
    }

    private func modelPicker(_ title: String, detail: String, selection: Binding<String>) -> some View {
        Picker(selection: selection) {
            ForEach(options(including: selection.wrappedValue), id: \.id) { m in
                Text(m.name).tag(m.id)
            }
        } label: {
            Text(title)
            Text(detail)
        }
        .disabled(models.isEmpty)
    }

    private func options(including current: String) -> [(id: String, name: String)] {
        var list = models.map { (id: $0.id, name: $0.displayName) }
        if !list.contains(where: { $0.id == current }) { list.insert((current, current), at: 0) }
        return list
    }

    private func loadModels() async {
        guard model.credentials != nil else { return }
        do {
            models = try await model.services.client.availableModels()
            modelsError = nil
        } catch {
            modelsError = "Couldn’t load the model list. Showing your current choices."
        }
    }
}

struct UsageMeter: View {
    let title: String
    let percent: Double?
    let resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if let percent {
                    Text("\(Int(percent.rounded()))% used")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Updates after the next request").foregroundStyle(.tertiary)
                }
            }
            if let percent {
                ProgressView(value: min(100, percent), total: 100)
                    .tint(tint)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int(percent.rounded())) percent used")
            }
            if let resetsAt, resetsAt > Date() {
                Text("Resets \(resetsAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch percent ?? 0 {
        case 90...: .red
        case 70...: .orange
        default: .accentColor
        }
    }
}

import StandardKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                Color.clear
            case .welcome:
                WelcomeView()
            case .onboarding:
                OnboardingView()
            case .building:
                BuildingView()
            case .library:
                MainView()
            case .failed(let message):
                ContentUnavailableView("Something went wrong", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .frame(minWidth: 960, minHeight: 640)
    }
}

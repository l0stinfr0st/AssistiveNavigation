import SwiftUI
import SwiftData

@main
struct FadiBlindApp: App {

    let container: ModelContainer

    @StateObject private var viewModel: AppViewModel

    init() {
        let c = try! ModelContainer(for: AppUser.self, HazardReport.self, NavigationSession.self)
        container = c
        _viewModel = StateObject(wrappedValue: AppViewModel(container: c))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(viewModel)
                .task {
                    await viewModel.bootstrap()
                }
        }
        .modelContainer(container)
    }
}

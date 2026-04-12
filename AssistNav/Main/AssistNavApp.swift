import SwiftUI

@main
struct AssistNavApp: App {
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var streamingSettings = DepthStreamingSettings.shared

    init() {
        UserDefaults.standard.register(defaults: [
            "launch_lidar_capture_test": false
        ])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(viewModel)
                .environmentObject(streamingSettings)
                .task {
                    await viewModel.bootstrap()
                }
        }
    }
}
